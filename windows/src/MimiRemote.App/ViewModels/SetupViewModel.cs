using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Xaml;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed class SetupViewModel : ClientPageViewModel
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly OnboardingWizardStateMachine wizard;
    private string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "code");
    private string? maintenanceFallbackDownloadUrl;
    private bool preserveMaintenanceNotice;

    public OnboardingWizardStateMachine Wizard => wizard;

    public bool IsPendingWorkspaceConfirmation =>
        Context.GateState == OnboardingGateState.PendingConfirmation
        && Context.RunInstallerMaintenance is not null
        && !Context.Preview;

    public bool HasMaintenanceDownloadFallback =>
        !string.IsNullOrWhiteSpace(maintenanceFallbackDownloadUrl) || wizard.HasMaintenanceFallbackDownload;

    public string Root
    {
        get => root;
        set => SetProperty(ref root, value);
    }

    public event EventHandler<string?>? QrPayloadChanged;

    public IAsyncRelayCommand PickCommand { get; }
    public IAsyncRelayCommand FinishCommand { get; }
    public IAsyncRelayCommand BackCommand { get; }
    public IAsyncRelayCommand NextFromStep1Command { get; }
    public IAsyncRelayCommand RetryServiceCommand { get; }
    public IAsyncRelayCommand NextFromStep3Command { get; }
    public IRelayCommand<string> SelectTransportCommand { get; }
    public IAsyncRelayCommand EnableTransportCommand { get; }
    public IAsyncRelayCommand GenerateQrCommand { get; }
    public IRelayCommand CopyLinkCommand { get; }
    public IRelayCommand CompleteWizardCommand { get; }
    public IAsyncRelayCommand<string> RowPrimaryActionCommand { get; }
    public IAsyncRelayCommand<string> RowSecondaryActionCommand { get; }
    public IAsyncRelayCommand<string> ResetRuntimePinCommand { get; }
    public IAsyncRelayCommand ConfirmWorkspaceViaMaintenanceCommand { get; }
    public IRelayCommand OpenMaintenanceDownloadCommand { get; }
    public IRelayCommand OpenDiagnosticsCommand { get; }

    public SetupViewModel(ClientContext context) : base(context)
    {
        wizard = new OnboardingWizardStateMachine(new ClientContextWizardBackend(context), context.VerifiedCapability)
        {
            RequestPathAsync = HandlePathPickerAsync,
        };
        wizard.PropertyChanged += OnWizardPropertyChanged;
        wizard.GateEvaluated += (_, state) =>
        {
            // The shared reader publishes preflight results. A save may also discover a recovery lock.
            if (wizard.IsSavingSetup && state == OnboardingGateState.RecoveryLocked && wizard.PreflightError is { } error)
            {
                Context.UpdateGateFromPreflight(null, error);
            }
        };
        wizard.DeepSeekConnectRequested += (_, _) =>
        {
            if (Context.GateState == OnboardingGateState.Confirmed)
            {
                Context.NavigateRoute(OnboardingNavigationGate.RouteAssistants);
            }
            else
            {
                Report("请先保存配置并启动服务，再在“AI 助手”页面连接 DeepSeek Harness。");
            }
        };
        wizard.IssuedTicketChanged += (_, payload) => QrPayloadChanged?.Invoke(this, payload);

        timer.Tick += (_, _) => wizard.TickCountdown();

        PickCommand = new AsyncRelayCommand(() => RunAsync(async () =>
        {
            if (await Context.PickFolder() is { Length: > 0 } folder)
            {
                Root = folder;
                await wizard.SelectWorkspaceRootAsync(folder, Lifetime.Token);
            }
        }));
        FinishCommand = new AsyncRelayCommand(() => RunAsync(SaveWorkspaceAsync));
        BackCommand = new AsyncRelayCommand(() => RunAsync(() => wizard.GoBackAsync(Lifetime.Token)));
        NextFromStep1Command = new AsyncRelayCommand(() => RunAsync(() => wizard.ProceedToWorkspaceStepAsync(Lifetime.Token)));
        RetryServiceCommand = new AsyncRelayCommand(() => RunAsync(() => wizard.EnsureServiceReadyAsync(Lifetime.Token)));
        NextFromStep3Command = new AsyncRelayCommand(() => RunAsync(() => wizard.ProceedToConnectStepAsync(Lifetime.Token)));
        SelectTransportCommand = new RelayCommand<string>(id =>
        {
            if (!string.IsNullOrWhiteSpace(id))
            {
                wizard.SelectTransport(id);
            }
        });
        EnableTransportCommand = new AsyncRelayCommand(() => RunAsync(() => wizard.EnableSelectedTransportAsync(cancellationToken: Lifetime.Token)));
        GenerateQrCommand = new AsyncRelayCommand(() => RunAsync(() => wizard.IssuePairingAsync(cancellationToken: Lifetime.Token)));
        CopyLinkCommand = new RelayCommand(() =>
        {
            if (wizard.CopyPairingLink())
            {
                Report("已复制短期配对链接。请勿发送给他人。");
            }
        });
        CompleteWizardCommand = new RelayCommand(() =>
        {
            if (Context.GateState == OnboardingGateState.Confirmed && wizard.CompleteWizard())
            {
                Context.NavigateRoute(OnboardingNavigationGate.RouteSessions);
            }
        }, () => Context.GateState == OnboardingGateState.Confirmed && wizard.CanCompleteWizard);
        context.GateStateChanged += OnGateStateChanged;
        RowPrimaryActionCommand = new AsyncRelayCommand<string>(id => RunAsync(async () =>
        {
            if (!string.IsNullOrWhiteSpace(id))
            {
                await wizard.PerformCheckPrimaryActionAsync(id, Lifetime.Token);
            }
        }));
        RowSecondaryActionCommand = new AsyncRelayCommand<string>(id => RunAsync(async () =>
        {
            if (!string.IsNullOrWhiteSpace(id))
            {
                await wizard.PerformCheckSecondaryActionAsync(id, Lifetime.Token);
            }
        }));
        ResetRuntimePinCommand = new AsyncRelayCommand<string>(checkId => RunAsync(async () =>
        {
            var runtimeId = checkId switch
            {
                "assistant_codex" => "codex",
                "assistant_claude" => "claude",
                "assistant_agy" => "agy",
                _ => null,
            };
            if (runtimeId is not null)
            {
                await wizard.ResetRuntimePathToAutoAsync(runtimeId, Lifetime.Token);
            }
        }));
        ConfirmWorkspaceViaMaintenanceCommand = new AsyncRelayCommand(
            () => RunAsync(ConfirmWorkspaceViaMaintenanceAsync),
            () => IsPendingWorkspaceConfirmation);
        OpenMaintenanceDownloadCommand = new RelayCommand(
            () =>
            {
                var url = maintenanceFallbackDownloadUrl ?? wizard.MaintenanceFallbackDownloadUrl;
                if (url is not null && OnboardingCopyCatalog.IsAllowedUrl(url))
                {
                    Context.OpenUrl(url);
                }
            },
            () => HasMaintenanceDownloadFallback);
        OpenDiagnosticsCommand = new RelayCommand(() => Context.NavigateRoute(OnboardingNavigationGate.RouteDiagnostics));
        PropertyChanged += (_, args) =>
        {
            if (string.Equals(args.PropertyName, nameof(NoticeOpen), StringComparison.Ordinal) && !NoticeOpen)
            {
                preserveMaintenanceNotice = false;
            }
        };
    }

    protected override void OnActiveChanged()
    {
        if (Active)
        {
            wizard.ReopenIfCompleted();
            timer.Start();
        }
        else
        {
            timer.Stop();
            wizard.InvalidateIssuedPairing();
        }
    }

    protected override async Task RefreshAsync(bool force)
    {
        if (Context.Preview)
        {
            return;
        }
        await wizard.RunPreflightAsync(cancellationToken: Lifetime.Token);
        if (!string.IsNullOrWhiteSpace(wizard.SelectedScanRoot))
        {
            Root = wizard.SelectedScanRoot;
        }
        if (wizard.PreflightError is { } err)
        {
            preserveMaintenanceNotice = false;
            Report(err.Message, error: true);
        }
        else if (wizard.StepError is null && wizard.PairingError is null && !preserveMaintenanceNotice)
        {
            NoticeOpen = false;
        }
    }

    private async Task SaveWorkspaceAsync()
    {
        if (Context.Preview)
        {
            throw new InvalidOperationException("界面预览不会更改代码目录或电脑服务。");
        }
        preserveMaintenanceNotice = false;
        var selected = Root.Trim();
        if (!Path.IsPathFullyQualified(selected))
        {
            throw new ArgumentException("请选择完整的代码目录路径。");
        }
        if (!string.Equals(wizard.SelectedScanRoot, selected, StringComparison.OrdinalIgnoreCase))
        {
            await wizard.SelectWorkspaceRootAsync(selected, Lifetime.Token);
        }
        var confirmCreate = false;
        if (!Directory.Exists(selected))
        {
            if (!await Context.Confirm("创建代码目录？", "所选文件夹不存在，是否创建后继续？"))
            {
                return;
            }
            confirmCreate = true;
        }
        await Context.ChangeAsync(() => wizard.SaveWorkspaceAndContinueAsync(confirmCreate, Lifetime.Token));
        if (wizard.StepError is { } error)
        {
            Report(error.Message, error: true);
        }
        else if (wizard.ServiceError is { } serviceErr)
        {
            Report(serviceErr.Message, error: true);
        }
        else
        {
            NoticeOpen = false;
        }
    }

    private async Task HandlePathPickerAsync(string target)
    {
        if (string.Equals(target, "workspace_root", StringComparison.Ordinal))
        {
            if (await Context.PickFolder() is { Length: > 0 } folder)
            {
                Root = folder;
                await wizard.SelectWorkspaceRootAsync(folder, Lifetime.Token);
            }
            return;
        }
        var runtimeId = target switch
        {
            "codex_bin" => "codex",
            "claude_bin" => "claude",
            "agy_bin" => "agy",
            _ => null,
        };
        if (runtimeId is not null && await Context.PickFile() is { Length: > 0 } file)
        {
            await wizard.SelectRuntimePathAsync(runtimeId, file, Lifetime.Token);
        }
    }

    private async Task ConfirmWorkspaceViaMaintenanceAsync()
    {
        if (!IsPendingWorkspaceConfirmation || Context.RunInstallerMaintenance is not { } runMaintenance)
        {
            return;
        }
        preserveMaintenanceNotice = false;
        SetMaintenanceFallbackUrl(null);
        var result = await runMaintenance(MaintenancePurpose.ConfirmWorkspace, Lifetime.Token);
        SetMaintenanceFallbackUrl(result.FallbackToDownload ? result.DownloadUrl : null);
        if (result.BrokerVerified)
        {
            if (result.PostRunPreflight is { } verifiedPreflight)
            {
                wizard.ApplyVerifiedPreflightReport(verifiedPreflight);
                Context.UpdateGateFromPreflight(verifiedPreflight);
            }
            else
            {
                await wizard.RunPreflightAsync(cancellationToken: Lifetime.Token);
            }
            if (!string.IsNullOrWhiteSpace(wizard.SelectedScanRoot))
            {
                Root = wizard.SelectedScanRoot;
            }
        }
        preserveMaintenanceNotice = true;
        Report(result.Message, error: !result.Succeeded);
    }

    private void SetMaintenanceFallbackUrl(string? url)
    {
        if (SetProperty(ref maintenanceFallbackDownloadUrl, url, nameof(HasMaintenanceDownloadFallback)))
        {
            OpenMaintenanceDownloadCommand.NotifyCanExecuteChanged();
        }
    }

    private void OnGateStateChanged(object? sender, OnboardingGateState state)
    {
        OnPropertyChanged(nameof(IsPendingWorkspaceConfirmation));
        ConfirmWorkspaceViaMaintenanceCommand.NotifyCanExecuteChanged();
        CompleteWizardCommand.NotifyCanExecuteChanged();
    }

    private void OnWizardPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(OnboardingWizardStateMachine.CanCompleteWizard))
        {
            CompleteWizardCommand.NotifyCanExecuteChanged();
        }
        if (args.PropertyName == nameof(OnboardingWizardStateMachine.HasMaintenanceFallbackDownload))
        {
            OnPropertyChanged(nameof(HasMaintenanceDownloadFallback));
            OpenMaintenanceDownloadCommand.NotifyCanExecuteChanged();
        }
        if (string.Equals(args.PropertyName, nameof(OnboardingWizardStateMachine.SelectedScanRoot), StringComparison.Ordinal)
            && !string.IsNullOrWhiteSpace(wizard.SelectedScanRoot))
        {
            Root = wizard.SelectedScanRoot;
        }
        else if (string.Equals(args.PropertyName, nameof(OnboardingWizardStateMachine.StepError), StringComparison.Ordinal)
            && wizard.StepError is { } stepErr)
        {
            Report(stepErr.Message, error: true);
        }
        else if (string.Equals(args.PropertyName, nameof(OnboardingWizardStateMachine.PairingError), StringComparison.Ordinal)
            && wizard.PairingError is { } pairErr)
        {
            if (wizard.LastLanMaintenanceResult is not null)
            {
                preserveMaintenanceNotice = true;
            }
            Report(pairErr.Message, error: true);
        }
    }

    public override void Dispose()
    {
        timer.Stop();
        Context.GateStateChanged -= OnGateStateChanged;
        wizard.PropertyChanged -= OnWizardPropertyChanged;
        wizard.Dispose();
        base.Dispose();
    }

    private sealed class ClientContextWizardBackend(ClientContext context) : IOnboardingWizardBackend
    {
        private readonly SynchronizationContext? uiContext = SynchronizationContext.Current;

        public Task<OnboardingPreflightReport> PreflightAsync(
            OnboardingPreflightOptions options,
            Action<OnboardingCheck>? onProgress,
            CancellationToken cancellationToken)
        {
            Action<OnboardingCheck>? marshaled = onProgress is null
                ? null
                : check =>
                {
                    if (uiContext is not null)
                    {
                        uiContext.Post(_ => onProgress(check), null);
                    }
                    else
                    {
                        onProgress(check);
                    }
                };
            return context.ReadPreflightAsync(options, marshaled, cancellationToken);
        }

        public Task<SetupReceipt> SetupNoPairAsync(string scanRoot, OnboardingSetupOptions options, CancellationToken cancellationToken) =>
            context.Agent.SetupAsync(scanRoot, options, cancellationToken);

        public Task<UpReadinessReceipt> UpAsync(int waitSeconds, CancellationToken cancellationToken) =>
            context.Agent.UpAsync(waitSeconds, cancellationToken);

        public Task<PairingTicketReceipt> PairAsync(string network, CancellationToken cancellationToken) =>
            context.Agent.PairAsync(network, cancellationToken);

        public Task SetRuntimePathAsync(string runtimeId, string value, CancellationToken cancellationToken) =>
            new ModuleCommands(context.Agent).SetRuntimePathAsync(runtimeId, value, restartIfRequired: true, cancellationToken);

        public Task<bool> UpdateWorkspaceAsync(string scanRoot, string? browseRoot, CancellationToken cancellationToken) =>
            new ModuleCommands(context.Agent).UpdateWorkspaceConfigAsync(scanRoot, browseRoot, cancellationToken);

        public Task EnableAssistantAsync(string runtimeId, CancellationToken cancellationToken) =>
            new ModuleCommands(context.Agent).SetAsync(runtimeId, enabled: true, cancellationToken);

        public async Task EnableTransportAsync(string transport, CancellationToken cancellationToken)
        {
            if (string.Equals(transport, "tailcat", StringComparison.Ordinal))
            {
                await context.Agent.RunAsync(["tailcat", "enable", "--json"], cancellationToken);
            }
            else
            {
                await new ModuleCommands(context.Agent).SetAsync(transport, enabled: true, cancellationToken);
            }
        }

        public async Task<UpReadinessReceipt> RestartServiceAsync(CancellationToken cancellationToken)
        {
            var json = await context.Agent.RunAsync(["restart", "--wait", "60s", "--no-pair", "--json"], cancellationToken);
            return OnboardingCopyCatalog.TryDecodeUpReadinessReceipt(json, out var receipt, out _)
                ? receipt
                : throw new InvalidDataException("后台服务尚未确认就绪。");
        }

        public Func<CancellationToken, Task<MaintenanceRunResult>>? RunLanFirewallMaintenance =>
            context.RunInstallerMaintenance is { } run
                ? ct => run(MaintenancePurpose.LanFirewall, ct)
                : null;

        public bool DirectoryExists(string path) => Directory.Exists(path);
        public void CreateDirectory(string path) => Directory.CreateDirectory(path);
        public void OpenUrl(string url) => context.OpenUrl(url);
        public void OpenSettings(string target) => context.OpenSettings(target);
        public bool CopyToClipboard(string text) => context.CopyToClipboard(text);
        public DateTimeOffset Now() => DateTimeOffset.UtcNow;
    }
}
