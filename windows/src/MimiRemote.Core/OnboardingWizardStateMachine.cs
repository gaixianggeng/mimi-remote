using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;

namespace MimiRemote.Core;

public enum OnboardingGateState
{
    Unconfigured,
    PendingConfirmation,
    Confirmed,
    RecoveryLocked,
}

public static class OnboardingNavigationGate
{
    public const string RouteSessions = "sessions";
    public const string RouteOverview = "overview";
    public const string RouteSetup = "setup";
    public const string RoutePair = "pair";
    public const string RouteConnection = "connection";
    public const string RouteAssistants = "assistants";
    public const string RouteDiagnostics = "diagnostics";
    public const string RouteSettings = "settings";

    public static IReadOnlyList<string> AllRoutes { get; } =
    [
        RouteSessions,
        RouteOverview,
        RouteSetup,
        RoutePair,
        RouteConnection,
        RouteAssistants,
        RouteDiagnostics,
        RouteSettings,
    ];

    private static readonly HashSet<string> AllowedRoutesWhenLocked = new(StringComparer.Ordinal)
    {
        RouteSetup,
        RouteDiagnostics,
        RouteSettings,
    };

    private static readonly HashSet<string> RecoveryCodes = new(StringComparer.Ordinal)
    {
        "config_invalid",
        "config_recovery_required",
        "token_rotation_requires_approval",
        "legacy_codex_residue",
        "config_requires_newer_version",
        "config_permissions_unsafe",
        "config_dir_unwritable",
    };

    public static OnboardingGateState Evaluate(
        OnboardingPreflightReport? report,
        OnboardingResolvedDiagnostic? preflightError = null,
        bool preview = false)
    {
        if (preview)
        {
            return OnboardingGateState.Confirmed;
        }
        if (report is not null)
        {
            var configCheck = report.Checks.FirstOrDefault(c => string.Equals(c.Id, "config_store", StringComparison.Ordinal));
            if (configCheck is not null && IsRecoveryCheck(configCheck))
            {
                return OnboardingGateState.RecoveryLocked;
            }
            if (!report.Configured)
            {
                return OnboardingGateState.Unconfigured;
            }
            if (!report.WorkspaceConfirmed)
            {
                return OnboardingGateState.PendingConfirmation;
            }
            return OnboardingGateState.Confirmed;
        }
        if (preflightError is not null && IsRecoveryDiagnostic(preflightError))
        {
            return OnboardingGateState.RecoveryLocked;
        }
        return OnboardingGateState.Unconfigured;
    }

    public static bool IsRouteAllowed(OnboardingGateState state, string route) =>
        state == OnboardingGateState.Confirmed
            ? AllRoutes.Contains(route, StringComparer.Ordinal)
            : AllowedRoutesWhenLocked.Contains(route);

    public static bool IsSettingsEditable(OnboardingGateState state) =>
        state == OnboardingGateState.Confirmed;

    public static string HomeRoute(OnboardingGateState state) =>
        state == OnboardingGateState.Confirmed ? RouteSessions : RouteSetup;

    public static string ResolveRoute(OnboardingGateState state, string? requestedRoute)
    {
        if (string.IsNullOrWhiteSpace(requestedRoute) || !AllRoutes.Contains(requestedRoute, StringComparer.Ordinal))
        {
            return HomeRoute(state);
        }
        return IsRouteAllowed(state, requestedRoute) ? requestedRoute : HomeRoute(state);
    }

    public static string ResolveActivationRoute(OnboardingGateState state, bool pairRequested) =>
        pairRequested
            ? ResolveRoute(state, RoutePair)
            : HomeRoute(state);

    public static string DescribeState(OnboardingGateState state) => state switch
    {
        OnboardingGateState.Unconfigured => "尚未完成首次设置，请先选择代码目录并启动服务。",
        OnboardingGateState.PendingConfirmation => "后台服务已安装，但尚未确认代码目录。请确认目录后继续。",
        OnboardingGateState.RecoveryLocked => "配置文件需要查看恢复信息，已锁定业务页面以保护已有配对身份。",
        _ => "电脑端已完成首次设置。",
    };

    private static bool IsRecoveryCheck(OnboardingCheck check) =>
        string.Equals(check.State, "error", StringComparison.Ordinal)
        || (check.Code is not null && RecoveryCodes.Contains(check.Code))
        || (check.Fix is { Kind: "open_settings", Target: "host_recovery" });

    private static bool IsRecoveryDiagnostic(OnboardingResolvedDiagnostic diag) =>
        (diag.Code is not null && RecoveryCodes.Contains(diag.Code))
        || (diag.AllowedFix is { Kind: "open_settings", Target: "host_recovery" });
}

public enum OnboardingWizardStep
{
    EnvironmentCheck = 1,
    WorkspaceSelection = 2,
    ServiceAndPermissions = 3,
    ConnectPhone = 4,
}

public enum OnboardingServicePhase
{
    Idle,
    ConfigSaved,
    StartingService,
    Ready,
    Failed,
}

public sealed record OnboardingTransportItem(
    string Id,
    string Title,
    string Badge,
    string Detail,
    bool Enabled,
    bool Available,
    bool Ready,
    bool CanEnableInPlace,
    bool NeedsFirewallMaintenance,
    bool BlockedByPublicNetwork,
    string? Code,
    OnboardingFix? Fix);

public sealed record OnboardingWizardRow(
    OnboardingCheck Check,
    OnboardingResolvedDiagnostic? Diagnostic,
    string StateBadge,
    string Message,
    string? PrimaryLabel,
    bool HasPrimaryAction,
    string? SecondaryLabel,
    bool HasSecondaryAction,
    bool CanResetPin,
    bool Skipped,
    string CandidateSummary);

public interface IOnboardingWizardBackend
{
    Task<OnboardingPreflightReport> PreflightAsync(
        OnboardingPreflightOptions options,
        Action<OnboardingCheck>? onProgress,
        CancellationToken cancellationToken);
    Task<SetupReceipt> SetupNoPairAsync(string scanRoot, OnboardingSetupOptions options, CancellationToken cancellationToken);
    Task<UpReadinessReceipt> UpAsync(int waitSeconds, CancellationToken cancellationToken);
    Task<PairingTicketReceipt> PairAsync(string network, CancellationToken cancellationToken);
    Task SetRuntimePathAsync(string runtimeId, string value, CancellationToken cancellationToken);
    Task UpdateWorkspaceAsync(string scanRoot, string? browseRoot, CancellationToken cancellationToken);
    Task EnableAssistantAsync(string runtimeId, CancellationToken cancellationToken);
    Task EnableTransportAsync(string transport, CancellationToken cancellationToken);
    Task RestartServiceAsync(CancellationToken cancellationToken);
    Task RunSafeDoctorFixAsync(CancellationToken cancellationToken);
    Task<bool> RunLanFirewallMaintenanceAsync(CancellationToken cancellationToken);
    bool DirectoryExists(string path);
    void CreateDirectory(string path);
    void OpenUrl(string url);
    void OpenSettings(string target);
    bool CopyToClipboard(string text);
    DateTimeOffset Now();
}

public sealed class OnboardingWizardStateMachine : ObservableObject, IDisposable
{
    public static IReadOnlyList<string> OrderedTransportIds { get; } = ["tailscale", "tailcat", "lan"];

    private readonly IOnboardingWizardBackend backend;
    private readonly string? verifiedCapability;
    private readonly Dictionary<string, string> draftRuntimePaths = new(StringComparer.Ordinal);
    private readonly Dictionary<string, string> draftAssistants = new(StringComparer.Ordinal);
    private readonly HashSet<string> skippedCheckIds = new(StringComparer.Ordinal);
    private readonly Dictionary<string, OnboardingCheck> streamingChecksById = new(StringComparer.Ordinal);
    private readonly Dictionary<string, OnboardingResolvedDiagnostic> resolvedDiagnostics = new(StringComparer.Ordinal);

    private OnboardingWizardStep currentStep = OnboardingWizardStep.EnvironmentCheck;
    private OnboardingGateState gateState;
    private OnboardingPreflightReport? report;
    private IReadOnlyList<OnboardingCheck> checks = [];
    private IReadOnlyList<OnboardingWizardRow> rows = [];
    private IReadOnlyList<OnboardingTransportItem> transports = [];
    private bool isCheckingPreflight;
    private OnboardingResolvedDiagnostic? preflightError;
    private OnboardingResolvedDiagnostic? stepError;
    private OnboardingResolvedDiagnostic? recoveryDiagnostic;
    private bool isRecoveryVisible;

    private string selectedScanRoot = "";
    private string? persistedBrowseRoot;
    private bool scanRootExists;
    private bool hasUserEditedScanRoot;
    private bool needsCreateDirectoryConfirmation;
    private bool isSavingSetup;
    private bool isConfigured;
    private bool workspaceConfirmed;
    private bool hasCommittedConfig;
    private string? committedScanRoot;
    private bool hasCommittedCurrentDraft;
    private bool pendingSaveReadback;
    private string? uncertainSaveScanRoot;
    private string? uncertainSaveBrowseRoot;

    private OnboardingServicePhase servicePhase;
    private bool isStartingService;
    private OnboardingResolvedDiagnostic? serviceError;

    private string selectedTransport = "tailscale";
    private bool hasUserSelectedTransport;
    private bool isEnablingTransport;
    private bool isIssuingPairing;
    private string? issuedPairUrl;
    private DateTimeOffset? issuedExpiresAt;
    private string? issuedNetwork;
    private IReadOnlyList<string> issuedWarnings = [];
    private OnboardingResolvedDiagnostic? pairingError;
    private string countdownText = "";
    private bool didCopyPairingLink;

    private bool isApplyingFix;
    private bool isCompleted;
    private bool disposed;
    private ulong preflightGeneration;
    private CancellationTokenSource? preflightCts;
    private ulong pairingGeneration;
    private CancellationTokenSource? pairingCts;

    public event EventHandler<OnboardingGateState>? GateStateChanged;
    public event EventHandler<string>? PathPickerRequested;
    public event EventHandler? DeepSeekConnectRequested;
    public event EventHandler? WizardCompleted;
    public event EventHandler<string?>? IssuedTicketChanged;

    public OnboardingWizardStateMachine(IOnboardingWizardBackend backend, string? verifiedCapability = null)
    {
        this.backend = backend;
        this.verifiedCapability = verifiedCapability;
        transports = BuildTransportItems();
    }

    public OnboardingWizardStep CurrentStep
    {
        get => currentStep;
        private set
        {
            if (SetProperty(ref currentStep, value))
            {
                OnPropertyChanged(nameof(StepNumber));
                OnPropertyChanged(nameof(StepTitle));
                OnPropertyChanged(nameof(IsStep1));
                OnPropertyChanged(nameof(IsStep2));
                OnPropertyChanged(nameof(IsStep3));
                OnPropertyChanged(nameof(IsStep4));
                OnPropertyChanged(nameof(CanGoBack));
                OnPropertyChanged(nameof(CanCompleteWizard));
                OnPropertyChanged(nameof(CanIssuePairingQr));
                OnPropertyChanged(nameof(CanCopyPairingLink));
            }
        }
    }

    public int StepNumber => (int)CurrentStep;
    public string StepTitle => CurrentStep switch
    {
        OnboardingWizardStep.EnvironmentCheck => "1. 检查环境",
        OnboardingWizardStep.WorkspaceSelection => "2. 选择代码目录",
        OnboardingWizardStep.ServiceAndPermissions => "3. 后台服务与权限",
        OnboardingWizardStep.ConnectPhone => "4. 连接手机",
        _ => "首次设置",
    };

    public bool IsStep1 => CurrentStep == OnboardingWizardStep.EnvironmentCheck;
    public bool IsStep2 => CurrentStep == OnboardingWizardStep.WorkspaceSelection;
    public bool IsStep3 => CurrentStep == OnboardingWizardStep.ServiceAndPermissions;
    public bool IsStep4 => CurrentStep == OnboardingWizardStep.ConnectPhone;
    public bool CanGoBack => CurrentStep > OnboardingWizardStep.EnvironmentCheck && !IsMutating;
    public bool IsMutating => IsSavingSetup || IsStartingService || IsEnablingTransport || IsApplyingFix;

    public OnboardingGateState GateState
    {
        get => gateState;
        private set
        {
            if (SetProperty(ref gateState, value))
            {
                OnPropertyChanged(nameof(GateStateDescription));
                GateStateChanged?.Invoke(this, value);
            }
        }
    }

    public string GateStateDescription => OnboardingNavigationGate.DescribeState(GateState);
    public OnboardingPreflightReport? Report { get => report; private set => SetProperty(ref report, value); }
    public IReadOnlyList<OnboardingCheck> Checks { get => checks; private set => SetProperty(ref checks, value); }
    public IReadOnlyList<OnboardingWizardRow> Rows { get => rows; private set => SetProperty(ref rows, value); }
    public IReadOnlyList<OnboardingTransportItem> Transports { get => transports; private set => SetProperty(ref transports, value); }

    public bool IsCheckingPreflight
    {
        get => isCheckingPreflight;
        private set
        {
            if (SetProperty(ref isCheckingPreflight, value))
            {
                NotifyDerivedProperties();
            }
        }
    }

    public OnboardingResolvedDiagnostic? PreflightError
    {
        get => preflightError;
        private set
        {
            if (SetProperty(ref preflightError, value))
            {
                NotifyDerivedProperties();
            }
        }
    }

    public OnboardingResolvedDiagnostic? StepError { get => stepError; private set => SetProperty(ref stepError, value); }
    public OnboardingResolvedDiagnostic? RecoveryDiagnostic { get => recoveryDiagnostic; private set => SetProperty(ref recoveryDiagnostic, value); }
    public bool IsRecoveryVisible { get => isRecoveryVisible; set => SetProperty(ref isRecoveryVisible, value); }

    public string SelectedScanRoot
    {
        get => selectedScanRoot;
        private set
        {
            if (SetProperty(ref selectedScanRoot, value))
            {
                OnPropertyChanged(nameof(EffectiveBrowseRoot));
                OnPropertyChanged(nameof(HasDistinctBrowseRoot));
                OnPropertyChanged(nameof(CanProceedFromWorkspaceSelection));
            }
        }
    }

    public string? PersistedBrowseRoot
    {
        get => persistedBrowseRoot;
        private set
        {
            if (SetProperty(ref persistedBrowseRoot, value))
            {
                OnPropertyChanged(nameof(EffectiveBrowseRoot));
                OnPropertyChanged(nameof(HasDistinctBrowseRoot));
            }
        }
    }

    public string EffectiveBrowseRoot =>
        !IsConfigured
            ? SelectedScanRoot
            : !string.IsNullOrWhiteSpace(PersistedBrowseRoot)
                ? PersistedBrowseRoot
                : SelectedScanRoot;

    public bool HasDistinctBrowseRoot =>
        !string.IsNullOrWhiteSpace(EffectiveBrowseRoot)
        && !string.Equals(EffectiveBrowseRoot, SelectedScanRoot, StringComparison.OrdinalIgnoreCase);

    public bool ScanRootExists { get => scanRootExists; private set => SetProperty(ref scanRootExists, value); }
    public bool NeedsCreateDirectoryConfirmation { get => needsCreateDirectoryConfirmation; private set => SetProperty(ref needsCreateDirectoryConfirmation, value); }

    public bool IsSavingSetup
    {
        get => isSavingSetup;
        private set
        {
            if (SetProperty(ref isSavingSetup, value))
            {
                NotifyDerivedProperties();
            }
        }
    }

    public bool IsConfigured { get => isConfigured; private set => SetProperty(ref isConfigured, value); }
    public bool WorkspaceConfirmed { get => workspaceConfirmed; private set => SetProperty(ref workspaceConfirmed, value); }
    public bool HasCommittedConfig { get => hasCommittedConfig; private set => SetProperty(ref hasCommittedConfig, value); }

    public OnboardingServicePhase ServicePhase
    {
        get => servicePhase;
        private set
        {
            if (SetProperty(ref servicePhase, value))
            {
                OnPropertyChanged(nameof(ServicePhaseText));
                OnPropertyChanged(nameof(CanRetryServiceStart));
                NotifyDerivedProperties();
            }
        }
    }

    public string ServicePhaseText => ServicePhase switch
    {
        OnboardingServicePhase.ConfigSaved => "配置已保存，准备启动后台服务。",
        OnboardingServicePhase.StartingService => "正在启动并等待后台服务就绪（最多 60 秒）…",
        OnboardingServicePhase.Ready => "后台服务已就绪。",
        OnboardingServicePhase.Failed => ServiceError?.Message ?? "后台服务未能启动。你可以直接重试启动，无需重新保存配置。",
        _ => "尚未启动后台服务。",
    };

    public bool IsStartingService
    {
        get => isStartingService;
        private set
        {
            if (SetProperty(ref isStartingService, value))
            {
                NotifyDerivedProperties();
            }
        }
    }

    public OnboardingResolvedDiagnostic? ServiceError
    {
        get => serviceError;
        private set
        {
            if (SetProperty(ref serviceError, value))
            {
                OnPropertyChanged(nameof(ServicePhaseText));
            }
        }
    }

    public bool CanRetryServiceStart => IsConfigured && !IsStartingService && !IsSavingSetup && ServicePhase != OnboardingServicePhase.Ready;

    public string SelectedTransport
    {
        get => selectedTransport;
        private set
        {
            if (SetProperty(ref selectedTransport, value))
            {
                OnPropertyChanged(nameof(SelectedTransportItem));
                OnPropertyChanged(nameof(CanIssuePairingQr));
                OnPropertyChanged(nameof(CanCopyPairingLink));
                OnPropertyChanged(nameof(CanEnableSelectedTransport));
            }
        }
    }

    public OnboardingTransportItem? SelectedTransportItem =>
        Transports.FirstOrDefault(t => string.Equals(t.Id, SelectedTransport, StringComparison.Ordinal));

    public bool IsEnablingTransport
    {
        get => isEnablingTransport;
        private set
        {
            if (SetProperty(ref isEnablingTransport, value))
            {
                NotifyDerivedProperties();
            }
        }
    }

    public bool IsIssuingPairing
    {
        get => isIssuingPairing;
        private set
        {
            if (SetProperty(ref isIssuingPairing, value))
            {
                NotifyDerivedProperties();
            }
        }
    }

    public bool HasIssuedTicket => !string.IsNullOrWhiteSpace(issuedPairUrl) && !IsIssuedTicketExpired;
    public DateTimeOffset? IssuedExpiresAt => issuedExpiresAt;
    public IReadOnlyList<string> IssuedWarnings => issuedWarnings;
    public OnboardingResolvedDiagnostic? PairingError { get => pairingError; private set => SetProperty(ref pairingError, value); }
    public string CountdownText { get => countdownText; private set => SetProperty(ref countdownText, value); }
    public bool DidCopyPairingLink { get => didCopyPairingLink; private set => SetProperty(ref didCopyPairingLink, value); }

    public bool IsApplyingFix
    {
        get => isApplyingFix;
        private set
        {
            if (SetProperty(ref isApplyingFix, value))
            {
                NotifyDerivedProperties();
            }
        }
    }

    public bool IsCompleted
    {
        get => isCompleted;
        private set
        {
            if (SetProperty(ref isCompleted, value))
            {
                OnPropertyChanged(nameof(CanCompleteWizard));
            }
        }
    }

    public bool IsIssuedTicketExpired =>
        issuedExpiresAt is DateTimeOffset expiry && backend.Now() >= expiry;

    public bool CanProceedFromEnvironmentCheck
    {
        get
        {
            if (IsCheckingPreflight || PreflightError is not null || Report is null
                || !string.Equals(Report.Stage, "setup", StringComparison.Ordinal))
            {
                return false;
            }
            var configCheck = GetCheck("config_store");
            return configCheck is null || !configCheck.Blocking;
        }
    }

    public bool CanProceedFromWorkspaceSelection
    {
        get
        {
            if (IsCheckingPreflight || IsSavingSetup || PreflightError is not null
                || pendingSaveReadback || Report is null
                || !string.Equals(Report.Stage, "setup", StringComparison.Ordinal)
                || string.IsNullOrWhiteSpace(SelectedScanRoot)
                || !Path.IsPathFullyQualified(SelectedScanRoot))
            {
                return false;
            }
            foreach (var check in Report.Checks)
            {
                if (!check.Blocking)
                {
                    continue;
                }
                var isMissingFolder = string.Equals(check.Id, "workspace_root", StringComparison.Ordinal)
                    && string.Equals(check.Code, "workspace_not_found", StringComparison.Ordinal)
                    && !Report.ScanRootExists;
                if (!isMissingFolder)
                {
                    return false;
                }
            }
            return true;
        }
    }

    public bool CanIssuePairingQr =>
        !IsCheckingPreflight
        && !IsEnablingTransport
        && PreflightError is null
        && Report is { Stage: "pair", Ok: true }
        && IsTransportReady(SelectedTransport);

    public bool CanEnableSelectedTransport =>
        CurrentStep == OnboardingWizardStep.ConnectPhone
        && !IsCheckingPreflight
        && !IsEnablingTransport
        && Report is { Stage: "pair", Configured: true }
        && SelectedTransportItem is { CanEnableInPlace: true };

    public bool CanCopyPairingLink =>
        CanIssuePairingQr
        && HasIssuedTicket
        && string.Equals(issuedNetwork, SelectedTransport, StringComparison.Ordinal);

    public bool CanCompleteWizard =>
        !IsCompleted
        && !IsMutating
        && !IsCheckingPreflight
        && PreflightError is null
        && Report is { Configured: true, WorkspaceConfirmed: true }
        && string.Equals(GetCheck("service_daemon")?.State, "ok", StringComparison.Ordinal)
        && GateState == OnboardingGateState.Confirmed;

    public IReadOnlyList<(string Id, string Value)> DraftRuntimePathsSnapshot =>
        [.. draftRuntimePaths.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => (p.Key, p.Value))];

    public IReadOnlyList<(string Id, string Value)> DraftAssistantsSnapshot =>
        [.. draftAssistants.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => (p.Key, p.Value))];

    public string PreflightStageForCurrentStep => CurrentStep switch
    {
        OnboardingWizardStep.EnvironmentCheck or OnboardingWizardStep.WorkspaceSelection => "setup",
        OnboardingWizardStep.ServiceAndPermissions => IsConfigured ? "pair" : "setup",
        OnboardingWizardStep.ConnectPhone => "pair",
        _ => "setup",
    };

    public OnboardingCheck? GetCheck(string id) =>
        Checks.FirstOrDefault(c => string.Equals(c.Id, id, StringComparison.Ordinal));

    public OnboardingResolvedDiagnostic? GetDiagnostic(string id) =>
        resolvedDiagnostics.TryGetValue(id, out var diag) ? diag : null;

    public bool IsTransportReady(string transport)
    {
        var row = GetCheck($"network_{transport}");
        return row is { State: "ok", Enabled: true, Available: true };
    }

    public Task StartAsync(CancellationToken cancellationToken = default) =>
        RunPreflightAsync("setup", cancellationToken);

    public async Task GoToStepAsync(OnboardingWizardStep step, CancellationToken cancellationToken = default)
    {
        if (disposed || IsCompleted || IsMutating || step == CurrentStep)
        {
            return;
        }
        if (CurrentStep == OnboardingWizardStep.ConnectPhone)
        {
            InvalidateIssuedPairing();
        }
        CancelPreflight();
        StepError = null;
        NeedsCreateDirectoryConfirmation = false;
        CurrentStep = step;
        await RunPreflightAsync(PreflightStageForCurrentStep, cancellationToken).ConfigureAwait(false);
    }

    public Task GoBackAsync(CancellationToken cancellationToken = default)
    {
        var previous = (int)CurrentStep - 1;
        return previous >= 1
            ? GoToStepAsync((OnboardingWizardStep)previous, cancellationToken)
            : Task.CompletedTask;
    }

    public Task ProceedToWorkspaceStepAsync(CancellationToken cancellationToken = default) =>
        GoToStepAsync(OnboardingWizardStep.WorkspaceSelection, cancellationToken);

    public Task ProceedToConnectStepAsync(CancellationToken cancellationToken = default) =>
        GoToStepAsync(OnboardingWizardStep.ConnectPhone, cancellationToken);

    public void CancelPreflight()
    {
        preflightGeneration++;
        preflightCts?.Cancel();
        preflightCts?.Dispose();
        preflightCts = null;
        IsCheckingPreflight = false;
    }

    public async Task RunPreflightAsync(string? stage = null, CancellationToken cancellationToken = default)
    {
        if (disposed || IsCompleted)
        {
            return;
        }
        var targetStage = stage ?? PreflightStageForCurrentStep;
        CancelPreflight();
        var generation = ++preflightGeneration;
        var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        preflightCts = cts;
        streamingChecksById.Clear();
        resolvedDiagnostics.Clear();
        IsCheckingPreflight = true;
        PreflightError = null;
        if (IsIssuingPairing)
        {
            InvalidateIssuedPairing();
        }

        var options = BuildPreflightOptions(targetStage);
        try
        {
            var finalReport = await backend.PreflightAsync(
                options,
                streamed => ApplyStreamedCheck(streamed, targetStage, generation),
                cts.Token).ConfigureAwait(false);

            if (cts.Token.IsCancellationRequested || generation != preflightGeneration || disposed)
            {
                return;
            }

            if (pendingSaveReadback && string.Equals(targetStage, "setup", StringComparison.Ordinal) && !finalReport.Configured)
            {
                pendingSaveReadback = false;
                uncertainSaveScanRoot = null;
                uncertainSaveBrowseRoot = null;
                IsConfigured = false;
                WorkspaceConfirmed = false;
                HasCommittedConfig = false;
                hasCommittedCurrentDraft = false;
                committedScanRoot = null;
            }

            ApplyFinalReport(finalReport);
        }
        catch (OperationCanceledException)
        {
            if (generation == preflightGeneration)
            {
                IsCheckingPreflight = false;
            }
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            if (cts.Token.IsCancellationRequested || generation != preflightGeneration || disposed)
            {
                return;
            }
            IsCheckingPreflight = false;
            InvalidateIssuedPairing();
            var diag = DiagnosticFromException(error, "service_daemon");
            PreflightError = diag;
            GateState = OnboardingNavigationGate.Evaluate(null, diag);
            if (diag.AllowedFix is { Kind: "open_settings", Target: "host_recovery" })
            {
                RecoveryDiagnostic = diag;
            }
        }
    }

    public void SetDraftScanRoot(string path)
    {
        var trimmed = path.Trim();
        SelectedScanRoot = trimmed;
        hasUserEditedScanRoot = true;
        NeedsCreateDirectoryConfirmation = false;
        if (!IsConfigured)
        {
            PersistedBrowseRoot = null;
        }
        ScanRootExists = Path.IsPathFullyQualified(trimmed) && backend.DirectoryExists(trimmed);
    }

    public async Task SelectWorkspaceRootAsync(string path, CancellationToken cancellationToken = default)
    {
        SetDraftScanRoot(path);
        StepError = null;
        await RunPreflightAsync("setup", cancellationToken).ConfigureAwait(false);
    }

    public void CancelCreateDirectoryConfirmation() => NeedsCreateDirectoryConfirmation = false;

    public async Task SaveWorkspaceAndContinueAsync(bool confirmCreateMissingDirectory = false, CancellationToken cancellationToken = default)
    {
        if (disposed || IsSavingSetup)
        {
            return;
        }
        if (pendingSaveReadback)
        {
            await RunPreflightAsync("setup", cancellationToken).ConfigureAwait(false);
            return;
        }
        var scanRoot = SelectedScanRoot.Trim();
        if (!Path.IsPathFullyQualified(scanRoot))
        {
            StepError = new OnboardingResolvedDiagnostic
            {
                Code = "invalid_request",
                Step = "workspace_root",
                Message = "请选择完整的代码目录路径。",
                AllowedFix = OnboardingFix.ChoosePath("workspace_root"),
                Trusted = true,
            };
            return;
        }
        if (Report is not null && !CanProceedFromWorkspaceSelection)
        {
            return;
        }

        var browseRoot = string.IsNullOrWhiteSpace(EffectiveBrowseRoot) ? scanRoot : EffectiveBrowseRoot.Trim();
        var existsNow = backend.DirectoryExists(scanRoot);
        ScanRootExists = existsNow;
        if (!existsNow)
        {
            if (!confirmCreateMissingDirectory)
            {
                NeedsCreateDirectoryConfirmation = true;
                return;
            }
            NeedsCreateDirectoryConfirmation = false;
            try
            {
                backend.CreateDirectory(scanRoot);
                ScanRootExists = true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException)
            {
                StepError = new OnboardingResolvedDiagnostic
                {
                    Code = "workspace_unreadable",
                    Step = "workspace_root",
                    Message = "无法创建所选代码目录。请检查位置权限或重新选择目录。",
                    AllowedFix = OnboardingFix.ChoosePath("workspace_root"),
                    Trusted = true,
                };
                return;
            }
        }

        NeedsCreateDirectoryConfirmation = false;
        IsSavingSetup = true;
        StepError = null;
        CancelPreflight();

        var saved = false;
        try
        {
            // Already saved this exact workspace in this wizard session: skip saving and go straight to service start.
            if (hasCommittedCurrentDraft
                && string.Equals(committedScanRoot, scanRoot, StringComparison.OrdinalIgnoreCase))
            {
                saved = true;
            }
            else if (HasCommittedConfig || IsConfigured)
            {
                // Existing or pending-confirmation config: update via `workspace --scan-root [--browse-root]`, never replay `setup --no-pair`.
                var preserveDistinctBrowse = !string.IsNullOrWhiteSpace(PersistedBrowseRoot);
                var needsWorkspaceUpdate = !WorkspaceConfirmed
                    || !string.Equals(Report?.ScanRoot, scanRoot, StringComparison.OrdinalIgnoreCase)
                    || (!preserveDistinctBrowse && !string.Equals(Report?.BrowseRoot, scanRoot, StringComparison.OrdinalIgnoreCase));
                if (needsWorkspaceUpdate)
                {
                    await backend.UpdateWorkspaceAsync(
                        scanRoot,
                        preserveDistinctBrowse ? null : scanRoot,
                        cancellationToken).ConfigureAwait(false);
                }
                HasCommittedConfig = true;
                committedScanRoot = scanRoot;
                hasCommittedCurrentDraft = true;
                IsConfigured = true;
                WorkspaceConfirmed = true;
                ServicePhase = OnboardingServicePhase.ConfigSaved;
                saved = true;
            }
            else
            {
                var setupOptions = new OnboardingSetupOptions
                {
                    BrowseRoot = browseRoot,
                    NoPair = true,
                    RuntimePaths = DraftRuntimePathsSnapshot,
                    Assistants = DraftAssistantsSnapshot,
                    VerifiedConfigured = false,
                };
                var receipt = await backend.SetupNoPairAsync(scanRoot, setupOptions, cancellationToken).ConfigureAwait(false);
                HasCommittedConfig = true;
                committedScanRoot = string.IsNullOrWhiteSpace(receipt.ScanRoot) ? scanRoot : receipt.ScanRoot;
                hasCommittedCurrentDraft = true;
                IsConfigured = receipt.Configured;
                WorkspaceConfirmed = true;
                SelectedScanRoot = committedScanRoot;
                PersistedBrowseRoot = !string.IsNullOrWhiteSpace(receipt.BrowseRoot)
                    && !string.Equals(receipt.BrowseRoot, committedScanRoot, StringComparison.OrdinalIgnoreCase)
                    ? receipt.BrowseRoot
                    : null;
                draftRuntimePaths.Clear();
                draftAssistants.Clear();
                ServicePhase = OnboardingServicePhase.ConfigSaved;
                saved = true;
            }
        }
        catch (OperationCanceledException)
        {
            pendingSaveReadback = true;
            uncertainSaveScanRoot = scanRoot;
            uncertainSaveBrowseRoot = browseRoot;
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            var diag = DiagnosticFromException(error, "config_store");
            StepError = diag;
            if (diag.AllowedFix is { Kind: "open_settings", Target: "host_recovery" })
            {
                RecoveryDiagnostic = diag;
                GateState = OnboardingGateState.RecoveryLocked;
            }
            if (string.Equals(diag.Code, "config_concurrent_change", StringComparison.Ordinal)
                || string.Equals(diag.Code, "command_timeout", StringComparison.Ordinal)
                || !diag.Trusted)
            {
                pendingSaveReadback = true;
                uncertainSaveScanRoot = scanRoot;
                uncertainSaveBrowseRoot = browseRoot;
            }
        }
        finally
        {
            IsSavingSetup = false;
        }

        if (pendingSaveReadback)
        {
            await RunPreflightAsync("setup", cancellationToken).ConfigureAwait(false);
            return;
        }

        if (saved)
        {
            CurrentStep = OnboardingWizardStep.ServiceAndPermissions;
            await EnsureServiceReadyAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task EnsureServiceReadyAsync(CancellationToken cancellationToken = default)
    {
        if (disposed || IsStartingService)
        {
            return;
        }
        if (!IsConfigured)
        {
            StepError = new OnboardingResolvedDiagnostic
            {
                Code = "config_missing",
                Step = "config_store",
                Message = OnboardingCopyCatalog.LocalizedMessage("config_missing", "config_store"),
                AllowedFix = OnboardingFix.RunFix("save_setup"),
                Trusted = true,
            };
            return;
        }

        IsStartingService = true;
        StepError = null;
        ServiceError = null;
        ServicePhase = OnboardingServicePhase.StartingService;
        try
        {
            var receipt = await backend.UpAsync(60, cancellationToken).ConfigureAwait(false);
            if (!receipt.ServiceOk)
            {
                throw new InvalidOperationException("后台服务尚未确认就绪。请重试。");
            }
            ServicePhase = OnboardingServicePhase.Ready;
        }
        catch (OperationCanceledException)
        {
            ServicePhase = OnboardingServicePhase.ConfigSaved;
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            var diag = DiagnosticFromException(error, "service_daemon");
            ServiceError = diag;
            StepError = diag;
            ServicePhase = OnboardingServicePhase.Failed;
        }
        finally
        {
            IsStartingService = false;
        }

        await RunPreflightAsync("pair", cancellationToken).ConfigureAwait(false);
    }

    public async Task SelectRuntimePathAsync(string runtimeId, string path, CancellationToken cancellationToken = default)
    {
        if (disposed || IsCompleted || IsApplyingFix)
        {
            return;
        }
        var trimmed = path.Trim();
        if (!string.Equals(trimmed, "auto", StringComparison.Ordinal) && !Path.IsPathFullyQualified(trimmed))
        {
            StepError = new OnboardingResolvedDiagnostic
            {
                Code = "invalid_request",
                Step = AssistantRuntimePresentation.CheckIdForRuntime(runtimeId),
                Message = "请选择程序的绝对路径。",
                AllowedFix = OnboardingFix.Retry,
                Trusted = true,
            };
            return;
        }
        StepError = null;
        if (!IsConfigured)
        {
            draftRuntimePaths[runtimeId] = trimmed;
            await RunPreflightAsync(PreflightStageForCurrentStep, cancellationToken).ConfigureAwait(false);
            return;
        }
        IsApplyingFix = true;
        try
        {
            await backend.SetRuntimePathAsync(runtimeId, trimmed, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or ArgumentException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            StepError = DiagnosticFromException(error, AssistantRuntimePresentation.CheckIdForRuntime(runtimeId));
            return;
        }
        finally
        {
            IsApplyingFix = false;
        }
        await RunPreflightAsync(PreflightStageForCurrentStep, cancellationToken).ConfigureAwait(false);
    }

    public Task ResetRuntimePathToAutoAsync(string runtimeId, CancellationToken cancellationToken = default) =>
        SelectRuntimePathAsync(runtimeId, "auto", cancellationToken);

    public async Task PerformCheckPrimaryActionAsync(string checkId, CancellationToken cancellationToken = default)
    {
        if (Report is null || !resolvedDiagnostics.TryGetValue(checkId, out var resolved)
            || !resolved.Trusted || resolved.AllowedFix is null)
        {
            return;
        }
        await DispatchTrustedFixAsync(resolved.AllowedFix, checkId, resolved.Code, resolved, cancellationToken).ConfigureAwait(false);
    }

    public async Task PerformCheckSecondaryActionAsync(string checkId, CancellationToken cancellationToken = default)
    {
        if (Report is null || !resolvedDiagnostics.TryGetValue(checkId, out var resolved)
            || !resolved.Trusted || resolved.SecondaryFix is null)
        {
            return;
        }
        await DispatchTrustedFixAsync(resolved.SecondaryFix, checkId, resolved.Code, resolved, cancellationToken).ConfigureAwait(false);
    }

    public async Task PerformDiagnosticActionAsync(OnboardingResolvedDiagnostic diagnostic, CancellationToken cancellationToken = default)
    {
        if (!diagnostic.Trusted || diagnostic.AllowedFix is null)
        {
            return;
        }
        await DispatchTrustedFixAsync(
            diagnostic.AllowedFix,
            diagnostic.Step ?? "service_daemon",
            diagnostic.Code,
            diagnostic,
            cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Selecting a transport only updates selection and clears previous ticket; zero writes.</summary>
    public void SelectTransport(string transport)
    {
        if (!OrderedTransportIds.Contains(transport, StringComparer.Ordinal))
        {
            return;
        }
        hasUserSelectedTransport = true;
        if (string.Equals(SelectedTransport, transport, StringComparison.Ordinal))
        {
            return;
        }
        SelectedTransport = transport;
        InvalidateIssuedPairing();
    }

    public async Task EnableSelectedTransportAsync(string? transport = null, CancellationToken cancellationToken = default)
    {
        var target = transport ?? SelectedTransport;
        if (disposed || CurrentStep != OnboardingWizardStep.ConnectPhone || IsEnablingTransport
            || Report is not { Stage: "pair", Configured: true }
            || !OrderedTransportIds.Contains(target, StringComparer.Ordinal))
        {
            return;
        }
        var item = Transports.FirstOrDefault(t => string.Equals(t.Id, target, StringComparison.Ordinal));
        if (item is null || item.Ready)
        {
            return;
        }
        SelectedTransport = target;
        hasUserSelectedTransport = true;
        PairingError = null;
        InvalidateIssuedPairing();

        if (string.Equals(target, "lan", StringComparison.Ordinal))
        {
            if (item.BlockedByPublicNetwork)
            {
                PairingError = GetDiagnostic("network_lan");
                backend.OpenSettings("windows_network_profile");
                return;
            }
            if (item.NeedsFirewallMaintenance)
            {
                IsEnablingTransport = true;
                try
                {
                    var configured = await backend.RunLanFirewallMaintenanceAsync(cancellationToken).ConfigureAwait(false);
                    if (!configured)
                    {
                        PairingError = GetDiagnostic("network_lan") ?? new OnboardingResolvedDiagnostic
                        {
                            Code = "lan_firewall_blocked",
                            Step = "network_lan",
                            Message = OnboardingCopyCatalog.LocalizedMessage("lan_firewall_blocked", "network_lan"),
                            AllowedFix = OnboardingFix.OpenSettings("windows_firewall"),
                            Trusted = true,
                        };
                        return;
                    }
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception error) when (error is OnboardingCliException or InvalidOperationException or InvalidDataException
                    or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
                {
                    PairingError = DiagnosticFromException(error, "network_lan");
                    return;
                }
                finally
                {
                    IsEnablingTransport = false;
                }
                await RunPreflightAsync("pair", cancellationToken).ConfigureAwait(false);
                if (IsTransportReady("lan"))
                {
                    await IssuePairingAsync("lan", cancellationToken).ConfigureAwait(false);
                }
                return;
            }
        }

        if (!item.CanEnableInPlace)
        {
            return;
        }

        IsEnablingTransport = true;
        try
        {
            await backend.EnableTransportAsync(target, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            PairingError = DiagnosticFromException(error, $"network_{target}");
            return;
        }
        finally
        {
            IsEnablingTransport = false;
        }

        await RunPreflightAsync("pair", cancellationToken).ConfigureAwait(false);
        if (CanIssuePairingQr && string.Equals(SelectedTransport, target, StringComparison.Ordinal))
        {
            await IssuePairingAsync(target, cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task IssuePairingAsync(string? transport = null, CancellationToken cancellationToken = default)
    {
        var target = transport ?? SelectedTransport;
        if (disposed || IsCompleted || CurrentStep != OnboardingWizardStep.ConnectPhone
            || !string.Equals(SelectedTransport, target, StringComparison.Ordinal)
            || !CanIssuePairingQr)
        {
            InvalidateIssuedPairing();
            return;
        }
        InvalidateIssuedPairing();
        var generation = ++pairingGeneration;
        var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        pairingCts = cts;
        IsIssuingPairing = true;
        PairingError = null;
        try
        {
            var receipt = await backend.PairAsync(target, cts.Token).ConfigureAwait(false);
            if (cts.Token.IsCancellationRequested || generation != pairingGeneration || disposed
                || CurrentStep != OnboardingWizardStep.ConnectPhone
                || !string.Equals(SelectedTransport, target, StringComparison.Ordinal)
                || !CanIssuePairingQr)
            {
                return;
            }
            if (!OnboardingCopyCatalog.IsValidPairUrl(receipt.PairUrl)
                || !OnboardingCopyCatalog.TryParseRfc3339Timestamp(receipt.PairExpiresAt, requireUtc: false, out var expiry)
                || expiry <= backend.Now())
            {
                PairingError = new OnboardingResolvedDiagnostic
                {
                    Code = "pair_ticket_invalid",
                    Step = "network_any",
                    Message = "配对信息无效或已经过期，请刷新二维码。",
                    AllowedFix = OnboardingFix.Retry,
                    Trusted = true,
                };
                return;
            }
            issuedPairUrl = receipt.PairUrl;
            issuedExpiresAt = expiry;
            issuedNetwork = target;
            issuedWarnings = receipt.Warnings;
            UpdateCountdown();
            NotifyTicketProperties();
            IssuedTicketChanged?.Invoke(this, issuedPairUrl);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            if (cts.Token.IsCancellationRequested || generation != pairingGeneration || disposed)
            {
                return;
            }
            PairingError = DiagnosticFromException(error, "network_any");
            InvalidateIssuedPairing(preserveError: true);
        }
        finally
        {
            if (generation == pairingGeneration)
            {
                IsIssuingPairing = false;
            }
        }
    }

    public bool CopyPairingLink()
    {
        TickCountdown();
        if (!CanCopyPairingLink || string.IsNullOrWhiteSpace(issuedPairUrl))
        {
            return false;
        }
        var copied = backend.CopyToClipboard(issuedPairUrl);
        DidCopyPairingLink = copied;
        return copied;
    }

    public void TickCountdown()
    {
        if (issuedPairUrl is null || issuedExpiresAt is not DateTimeOffset expiry)
        {
            return;
        }
        var remaining = expiry - backend.Now();
        if (remaining <= TimeSpan.Zero)
        {
            InvalidateIssuedPairing();
            CountdownText = "二维码已过期。请点击“刷新二维码”后重扫，已有配对不受影响。";
            return;
        }
        CountdownText = FormatCountdown(remaining, expiry);
    }

    public void InvalidateIssuedPairing(bool preserveError = false)
    {
        pairingGeneration++;
        pairingCts?.Cancel();
        pairingCts?.Dispose();
        pairingCts = null;
        IsIssuingPairing = false;
        var hadTicket = issuedPairUrl is not null;
        issuedPairUrl = null;
        issuedExpiresAt = null;
        issuedNetwork = null;
        issuedWarnings = [];
        DidCopyPairingLink = false;
        CountdownText = "";
        if (!preserveError)
        {
            PairingError = null;
        }
        NotifyTicketProperties();
        if (hadTicket)
        {
            IssuedTicketChanged?.Invoke(this, null);
        }
    }

    public bool CompleteWizard()
    {
        if (!CanCompleteWizard)
        {
            return false;
        }
        CancelPreflight();
        InvalidateIssuedPairing();
        IsCompleted = true;
        WizardCompleted?.Invoke(this, EventArgs.Empty);
        return true;
    }

    public static string FormatCountdown(TimeSpan remaining, DateTimeOffset expiresAt)
    {
        var totalSeconds = Math.Max(0, (int)Math.Ceiling(remaining.TotalSeconds));
        var minutes = totalSeconds / 60;
        var seconds = totalSeconds % 60;
        return string.Create(
            CultureInfo.InvariantCulture,
            $"剩余 {minutes:00}:{seconds:00}（有效期至 {expiresAt.ToLocalTime():HH:mm:ss}）");
    }

    private OnboardingPreflightOptions BuildPreflightOptions(string stage)
    {
        var scanRoot = string.Equals(stage, "setup", StringComparison.Ordinal) && !pendingSaveReadback && !string.IsNullOrWhiteSpace(SelectedScanRoot)
            ? SelectedScanRoot
            : null;
        var browseRoot = scanRoot is not null ? EffectiveBrowseRoot : null;
        return new OnboardingPreflightOptions
        {
            Stage = stage,
            ScanRoot = scanRoot,
            BrowseRoot = browseRoot,
            ProgressJson = true,
            RuntimePaths = string.Equals(stage, "setup", StringComparison.Ordinal) && !IsConfigured && !pendingSaveReadback
                ? DraftRuntimePathsSnapshot
                : [],
            Assistants = string.Equals(stage, "setup", StringComparison.Ordinal) && !IsConfigured && !pendingSaveReadback
                ? DraftAssistantsSnapshot
                : [],
            VerifiedConfigured = IsConfigured,
            VerifiedCapability = verifiedCapability,
        };
    }

    private void ApplyStreamedCheck(OnboardingCheck check, string stage, ulong generation)
    {
        if (disposed || generation != preflightGeneration)
        {
            return;
        }
        streamingChecksById[check.Id] = check;
        var ordered = new List<OnboardingCheck>();
        foreach (var id in OnboardingCopyCatalog.ApplicableCheckIds("windows"))
        {
            if (streamingChecksById.TryGetValue(id, out var existing))
            {
                ordered.Add(existing);
            }
        }
        var ctx = new OnboardingValidationContext
        {
            Surface = "check",
            Platform = "windows",
            Stage = stage,
            Configured = IsConfigured,
            VerifiedCapability = verifiedCapability,
        };
        if (OnboardingCopyCatalog.TryValidateCheck(check, ctx, out var diag, out _))
        {
            resolvedDiagnostics[check.Id] = diag;
        }
        Checks = ordered;
        RebuildRowsAndTransports();
    }

    private void ApplyFinalReport(OnboardingPreflightReport finalReport)
    {
        Report = finalReport;
        Checks = finalReport.Checks;
        IsConfigured = finalReport.Configured;
        WorkspaceConfirmed = finalReport.WorkspaceConfirmed;
        resolvedDiagnostics.Clear();

        foreach (var row in finalReport.Checks)
        {
            var ctx = new OnboardingValidationContext
            {
                Surface = "check",
                Platform = "windows",
                Stage = finalReport.Stage,
                Configured = finalReport.Configured,
                HasRecommendedTransport = true,
                RecommendedTransport = finalReport.RecommendedTransport,
                VerifiedCapability = verifiedCapability,
            };
            if (OnboardingCopyCatalog.TryValidateCheck(row, ctx, out var diag, out _))
            {
                resolvedDiagnostics[row.Id] = diag;
            }
        }

        if (string.Equals(finalReport.Stage, "setup", StringComparison.Ordinal) && pendingSaveReadback)
        {
            pendingSaveReadback = false;
            hasUserEditedScanRoot = false;
            if (finalReport.Configured)
            {
                HasCommittedConfig = true;
                committedScanRoot = finalReport.ScanRoot;
                hasCommittedCurrentDraft = finalReport.WorkspaceConfirmed && finalReport.Ok
                    && string.Equals(uncertainSaveScanRoot, finalReport.ScanRoot, StringComparison.OrdinalIgnoreCase)
                    && string.Equals(uncertainSaveBrowseRoot, finalReport.BrowseRoot, StringComparison.OrdinalIgnoreCase);
                draftRuntimePaths.Clear();
                draftAssistants.Clear();
            }
            uncertainSaveScanRoot = null;
            uncertainSaveBrowseRoot = null;
        }

        if (!hasUserEditedScanRoot || string.IsNullOrWhiteSpace(SelectedScanRoot))
        {
            SelectedScanRoot = finalReport.ScanRoot;
        }
        PersistedBrowseRoot = finalReport.Configured
            && !string.Equals(finalReport.BrowseRoot, finalReport.ScanRoot, StringComparison.OrdinalIgnoreCase)
            ? finalReport.BrowseRoot
            : null;
        ScanRootExists = string.Equals(SelectedScanRoot, finalReport.ScanRoot, StringComparison.OrdinalIgnoreCase)
            ? finalReport.ScanRootExists
            : Path.IsPathFullyQualified(SelectedScanRoot) && backend.DirectoryExists(SelectedScanRoot);

        var configDiag = GetDiagnostic("config_store");
        RecoveryDiagnostic = configDiag is { AllowedFix: { Kind: "open_settings", Target: "host_recovery" } }
            ? configDiag
            : null;

        var serviceCheck = GetCheck("service_daemon");
        if (serviceCheck is not null)
        {
            if (string.Equals(serviceCheck.State, "ok", StringComparison.Ordinal))
            {
                ServicePhase = OnboardingServicePhase.Ready;
                ServiceError = null;
            }
            else if (ServicePhase == OnboardingServicePhase.Ready)
            {
                ServicePhase = IsConfigured ? OnboardingServicePhase.ConfigSaved : OnboardingServicePhase.Idle;
            }
        }

        // Auto-select recommended transport with ZERO write operations.
        if (!hasUserSelectedTransport
            && finalReport.RecommendedTransport is { Length: > 0 } recommended
            && OrderedTransportIds.Contains(recommended, StringComparer.Ordinal)
            && !string.Equals(SelectedTransport, recommended, StringComparison.Ordinal))
        {
            InvalidateIssuedPairing();
            SelectedTransport = recommended;
        }

        GateState = OnboardingNavigationGate.Evaluate(finalReport, null);
        IsCheckingPreflight = false;
        RebuildRowsAndTransports();
        if (CurrentStep == OnboardingWizardStep.ConnectPhone && !CanIssuePairingQr)
        {
            InvalidateIssuedPairing();
        }
        NotifyDerivedProperties();
    }

    private async Task DispatchTrustedFixAsync(
        OnboardingFix fix,
        string checkId,
        string? code,
        OnboardingResolvedDiagnostic diagnostic,
        CancellationToken cancellationToken)
    {
        switch (fix.Kind)
        {
            case "open_url":
                if (fix.Url is not null && OnboardingCopyCatalog.IsAllowedUrl(fix.Url))
                {
                    backend.OpenUrl(fix.Url);
                }
                break;

            case "open_settings":
                if (fix.Target is null || !OnboardingCopyCatalog.IsAllowedSettingsTarget(fix.Target))
                {
                    break;
                }
                switch (fix.Target)
                {
                    case "connections":
                        await GoToStepAsync(OnboardingWizardStep.ConnectPhone, cancellationToken).ConfigureAwait(false);
                        break;
                    case "assistants":
                        await GoToStepAsync(OnboardingWizardStep.EnvironmentCheck, cancellationToken).ConfigureAwait(false);
                        break;
                    case "host_recovery":
                        RecoveryDiagnostic = diagnostic;
                        IsRecoveryVisible = true;
                        break;
                    case "windows_network_profile":
                    case "windows_firewall":
                    case "date_time":
                    case "managed_connection":
                        backend.OpenSettings(fix.Target);
                        break;
                }
                break;

            case "choose_path":
                if (fix.Target is null || !OnboardingCopyCatalog.IsAllowedPathTarget(fix.Target))
                {
                    break;
                }
                if (string.Equals(fix.Target, "workspace_root", StringComparison.Ordinal)
                    && CurrentStep != OnboardingWizardStep.WorkspaceSelection)
                {
                    await GoToStepAsync(OnboardingWizardStep.WorkspaceSelection, cancellationToken).ConfigureAwait(false);
                }
                PathPickerRequested?.Invoke(this, fix.Target);
                break;

            case "run_fix":
                if (fix.Action is not null)
                {
                    await DispatchRunFixActionAsync(fix.Action, checkId, code, cancellationToken).ConfigureAwait(false);
                }
                break;

            case "retry":
                StepError = null;
                await RunPreflightAsync(PreflightStageForCurrentStep, cancellationToken).ConfigureAwait(false);
                break;

            case "skip":
                skippedCheckIds.Add(checkId);
                RebuildRowsAndTransports();
                break;
        }
    }

    private async Task DispatchRunFixActionAsync(string action, string checkId, string? code, CancellationToken cancellationToken)
    {
        if (IsApplyingFix || IsCompleted || Report is null
            || !OnboardingCopyCatalog.RunFixSpecs.TryGetValue(action, out var spec))
        {
            return;
        }
        if (spec.RequiresConfig && !Report.Configured)
        {
            return;
        }
        if (action is "enable_tailscale" or "enable_tailcat" or "enable_lan"
            && CurrentStep != OnboardingWizardStep.ConnectPhone)
        {
            return;
        }
        if (string.Equals(action, "doctor_fix", StringComparison.Ordinal))
        {
            if (!string.Equals(verifiedCapability, OnboardingSchema.DoctorFixCapability, StringComparison.Ordinal)
                || !string.Equals(code, "config_permissions_unsafe", StringComparison.Ordinal))
            {
                return;
            }
        }

        switch (action)
        {
            case "save_setup":
                await GoToStepAsync(OnboardingWizardStep.WorkspaceSelection, cancellationToken).ConfigureAwait(false);
                break;

            case "enable_codex":
            case "enable_claude":
            case "enable_agy":
            {
                var runtimeId = action["enable_".Length..];
                if (!IsConfigured)
                {
                    draftAssistants[runtimeId] = "enabled";
                    await RunPreflightAsync(PreflightStageForCurrentStep, cancellationToken).ConfigureAwait(false);
                    return;
                }
                await RunGuardedFixAsync(
                    () => backend.EnableAssistantAsync(runtimeId, cancellationToken),
                    checkId,
                    cancellationToken).ConfigureAwait(false);
                break;
            }

            case "enable_tailscale":
                await EnableSelectedTransportAsync("tailscale", cancellationToken).ConfigureAwait(false);
                break;

            case "enable_tailcat":
                await EnableSelectedTransportAsync("tailcat", cancellationToken).ConfigureAwait(false);
                break;

            case "enable_lan":
                await EnableSelectedTransportAsync("lan", cancellationToken).ConfigureAwait(false);
                break;

            case "connect_deepseek":
                DeepSeekConnectRequested?.Invoke(this, EventArgs.Empty);
                break;

            case "register_service":
                if (CurrentStep != OnboardingWizardStep.ServiceAndPermissions)
                {
                    CurrentStep = OnboardingWizardStep.ServiceAndPermissions;
                }
                await EnsureServiceReadyAsync(cancellationToken).ConfigureAwait(false);
                break;

            case "restart_service":
                await RunGuardedFixAsync(
                    () => backend.RestartServiceAsync(cancellationToken),
                    "service_daemon",
                    cancellationToken).ConfigureAwait(false);
                break;

            case "doctor_fix":
                await RunGuardedFixAsync(
                    () => backend.RunSafeDoctorFixAsync(cancellationToken),
                    "config_store",
                    cancellationToken).ConfigureAwait(false);
                break;
        }
    }

    private async Task RunGuardedFixAsync(Func<Task> action, string step, CancellationToken cancellationToken)
    {
        IsApplyingFix = true;
        StepError = null;
        try
        {
            await action().ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception error) when (error is InvalidOperationException or InvalidDataException
            or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
        {
            StepError = DiagnosticFromException(error, step);
            return;
        }
        finally
        {
            IsApplyingFix = false;
        }
        await RunPreflightAsync(PreflightStageForCurrentStep, cancellationToken).ConfigureAwait(false);
    }

    private void RebuildRowsAndTransports()
    {
        var builtRows = new List<OnboardingWizardRow>(Checks.Count);
        foreach (var check in Checks)
        {
            var diag = GetDiagnostic(check.Id);
            var message = diag is { Trusted: true } ? diag.Message : check.Detail;
            var primary = diag is { Trusted: true } ? diag.AllowedFix : null;
            var secondary = diag is { Trusted: true } ? diag.SecondaryFix : null;
            var runtimeId = RuntimeIdForCheck(check.Id);
            var canResetPin = runtimeId is not null
                && (string.Equals(check.Source, "pin", StringComparison.Ordinal)
                    || string.Equals(check.Code, "runtime_path_invalid", StringComparison.Ordinal)
                    || (draftRuntimePaths.TryGetValue(runtimeId, out var draftVal)
                        && !string.Equals(draftVal, "auto", StringComparison.Ordinal)));
            builtRows.Add(new OnboardingWizardRow(
                check,
                diag,
                FormatStateBadge(check.State),
                message,
                primary is not null ? FormatFixLabel(primary) : null,
                primary is not null,
                diag?.SecondaryLabel ?? (secondary is not null ? FormatFixLabel(secondary) : null),
                secondary is not null,
                canResetPin,
                skippedCheckIds.Contains(check.Id),
                FormatCandidates(check.Candidates)));
        }
        Rows = builtRows;
        Transports = BuildTransportItems();
        OnPropertyChanged(nameof(SelectedTransportItem));
        OnPropertyChanged(nameof(CanEnableSelectedTransport));
    }

    private List<OnboardingTransportItem> BuildTransportItems()
    {
        var list = new List<OnboardingTransportItem>(3);
        foreach (var id in OrderedTransportIds)
        {
            var checkId = $"network_{id}";
            var check = GetCheck(checkId);
            var diag = GetDiagnostic(checkId);
            var title = id switch
            {
                "tailscale" => "Tailscale",
                "tailcat" => "内置连接（Tailcat）",
                _ => "同一局域网",
            };
            var enabled = check?.Enabled == true;
            var available = check?.Available == true;
            var ready = check is { State: "ok", Enabled: true, Available: true };
            var firewallBlocked = string.Equals(check?.Code, "lan_firewall_blocked", StringComparison.Ordinal);
            var publicBlocked = string.Equals(check?.Code, "lan_public_network_blocked", StringComparison.Ordinal);
            var canEnable = !ready && ((enabled == false && available) || firewallBlocked);
            var badge = ready
                ? "已就绪"
                : check is null
                    ? "正在检查"
                    : firewallBlocked
                        ? "需要防火墙规则"
                        : publicBlocked
                            ? "公用网络已阻止"
                            : available
                                ? "可启用"
                                : "暂不可用";
            var detail = diag is { Trusted: true }
                ? diag.Message
                : check?.Detail ?? "等待检查连接状态。";
            list.Add(new OnboardingTransportItem(
                id,
                title,
                badge,
                detail,
                enabled,
                available,
                ready,
                canEnable,
                firewallBlocked,
                publicBlocked,
                check?.Code,
                diag?.AllowedFix));
        }
        return list;
    }

    private void UpdateCountdown()
    {
        if (issuedExpiresAt is DateTimeOffset expiry)
        {
            CountdownText = FormatCountdown(expiry - backend.Now(), expiry);
        }
    }

    private void NotifyTicketProperties()
    {
        OnPropertyChanged(nameof(HasIssuedTicket));
        OnPropertyChanged(nameof(IssuedExpiresAt));
        OnPropertyChanged(nameof(IssuedWarnings));
        OnPropertyChanged(nameof(IsIssuedTicketExpired));
        OnPropertyChanged(nameof(CanCopyPairingLink));
    }

    private void NotifyDerivedProperties()
    {
        OnPropertyChanged(nameof(IsMutating));
        OnPropertyChanged(nameof(CanGoBack));
        OnPropertyChanged(nameof(CanProceedFromEnvironmentCheck));
        OnPropertyChanged(nameof(CanProceedFromWorkspaceSelection));
        OnPropertyChanged(nameof(CanRetryServiceStart));
        OnPropertyChanged(nameof(CanIssuePairingQr));
        OnPropertyChanged(nameof(CanEnableSelectedTransport));
        OnPropertyChanged(nameof(CanCopyPairingLink));
        OnPropertyChanged(nameof(CanCompleteWizard));
    }

    private static OnboardingResolvedDiagnostic DiagnosticFromException(Exception error, string defaultStep)
    {
        if (error is OnboardingCliException { Diagnostic: { } diag })
        {
            return diag;
        }
        if (error is TimeoutException)
        {
            return OnboardingCopyCatalog.SynthesizeLocal("command_timeout", defaultStep);
        }
        if (error is FileNotFoundException)
        {
            return OnboardingCopyCatalog.SynthesizeLocal("embedded_binary_missing", "service_daemon");
        }
        return new OnboardingResolvedDiagnostic
        {
            Step = defaultStep,
            Message = OnboardingCopyCatalog.SafeFallbackCopy,
            Trusted = false,
        };
    }

    private static string? RuntimeIdForCheck(string checkId) => checkId switch
    {
        "assistant_codex" => "codex",
        "assistant_claude" => "claude",
        "assistant_agy" => "agy",
        _ => null,
    };

    private static string FormatStateBadge(string state) => state switch
    {
        "ok" => "已就绪",
        "checking" => "检查中…",
        "optional" => "可选",
        "action_needed" => "需处理",
        "error" => "异常",
        _ => "未知",
    };

    public static string FormatFixLabel(OnboardingFix fix) => fix.Kind switch
    {
        "open_url" => "打开说明",
        "open_settings" => fix.Target switch
        {
            "host_recovery" => "查看恢复说明",
            "windows_firewall" => "检查防火墙规则",
            "windows_network_profile" => "打开网络设置",
            "connections" => "前往连接手机",
            "assistants" => "查看助手设置",
            "date_time" => "打开日期与时间",
            "managed_connection" => "查看托管连接",
            _ => "打开系统设置",
        },
        "choose_path" => string.Equals(fix.Target, "workspace_root", StringComparison.Ordinal)
            ? "选择代码目录…"
            : "手动选择程序…",
        "run_fix" => fix.Action switch
        {
            "save_setup" => "去选择代码目录",
            "enable_codex" => "启用 Codex",
            "enable_claude" => "启用 Claude Code",
            "enable_agy" => "启用 Antigravity",
            "connect_deepseek" => "连接 DeepSeek",
            "enable_tailscale" => "启用 Tailscale",
            "enable_tailcat" => "启用内置连接",
            "enable_lan" => "启用同一局域网",
            "register_service" => "注册并启动服务",
            "restart_service" => "重新加载服务",
            "doctor_fix" => "修复文件权限",
            _ => "执行修复",
        },
        "retry" => "重新检查",
        "skip" => "跳过此项",
        _ => "重新检查",
    };

    private static string FormatCandidates(IReadOnlyList<OnboardingCandidate>? candidates)
    {
        if (candidates is null || candidates.Count == 0)
        {
            return "";
        }
        var lines = new List<string>(candidates.Count);
        foreach (var c in candidates)
        {
            var outcomeText = c.Outcome switch
            {
                "selected" => "已选用",
                "compatible" => "兼容",
                "unsupported" => "版本不支持",
                "unusable" => "不可执行",
                "timeout" => "探测超时",
                "missing" => "不存在",
                _ => c.Outcome,
            };
            var ver = string.IsNullOrWhiteSpace(c.Version) ? "" : $" ({c.Version})";
            lines.Add($"{outcomeText}{ver}：{c.Path}");
        }
        return string.Join("\n", lines);
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        CancelPreflight();
        InvalidateIssuedPairing();
    }
}
