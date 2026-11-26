using CommunityToolkit.Mvvm.Input;
using MimiRemote.Core;

namespace MimiRemote.App.ViewModels;

public sealed class SettingsViewModel : ClientPageViewModel
{
    private readonly HttpClient updates = CreateClient();
    private WindowsRelease? release;
    private bool login;
    private bool notifications;
    private string serviceVersion = "尚未读取";
    private string scanRoot = "";
    private string browseRoot = "";
    private string? maintenanceFallbackDownloadUrl;

    public string ClientVersion => Context.Build.Display;
    public string ServiceVersion { get => serviceVersion; private set => SetProperty(ref serviceVersion, value); }
    public bool Login { get => login; set => SetProperty(ref login, value); }
    public bool Notifications { get => notifications; set => SetProperty(ref notifications, value); }
    public bool IsGateConfirmed => OnboardingNavigationGate.IsSettingsEditable(Context.GateState);
    public bool IsReadOnlyMode => !IsGateConfirmed;
    public bool IsPendingConfirmation => Context.GateState == OnboardingGateState.PendingConfirmation && Context.RunInstallerMaintenance is not null && !Context.Preview;
    public bool HasMaintenanceDownloadFallback => !string.IsNullOrWhiteSpace(maintenanceFallbackDownloadUrl);
    public string GateNotice => OnboardingNavigationGate.DescribeState(Context.GateState);
    public string ScanRoot { get => scanRoot; private set => SetProperty(ref scanRoot, value); }
    public string BrowseRoot
    {
        get => browseRoot;
        private set
        {
            if (SetProperty(ref browseRoot, value))
            {
                OnPropertyChanged(nameof(HasWidenedBrowseRoot));
                TightenBrowseRootCommand.NotifyCanExecuteChanged();
            }
        }
    }

    public bool HasWidenedBrowseRoot =>
        !string.IsNullOrWhiteSpace(ScanRoot)
        && !string.IsNullOrWhiteSpace(BrowseRoot)
        && !string.Equals(ScanRoot, BrowseRoot, StringComparison.OrdinalIgnoreCase);

    public bool CanCheckUpdates => Context.Build.CanCheckUpdates && !Context.Preview;
    public string UpdateNote => CanCheckUpdates ? "仅安装通过摘要、Windows 信任链和发布者证书校验的正式版本。" : "开发预览，自动更新将在正式安装版启用。";
    public string AvailableVersion => release is null ? "" : $"可用版本：{release.Version}";
    public bool CanInstall => release is not null && CanCheckUpdates && !IsBusy && IsGateConfirmed;
    public IAsyncRelayCommand SaveCommand { get; }
    public IAsyncRelayCommand CheckCommand { get; }
    public IAsyncRelayCommand InstallCommand { get; }
    public IAsyncRelayCommand WidenBrowseRootCommand { get; }
    public IAsyncRelayCommand TightenBrowseRootCommand { get; }
    public IRelayCommand NotifyCommand { get; }
    public IRelayCommand OpenSetupCommand { get; }
    public IRelayCommand OpenDiagnosticsCommand { get; }
    public IAsyncRelayCommand ConfirmWorkspaceViaMaintenanceCommand { get; }
    public IRelayCommand OpenMaintenanceDownloadCommand { get; }

    public SettingsViewModel(ClientContext context) : base(context)
    {
        login = !context.Preview && DesktopPreferences.LoginEnabled;
        notifications = context.Preferences.NotificationsEnabled;
        SaveCommand = new AsyncRelayCommand(() => RunAsync(() =>
        {
            if (Context.Preview)
            {
                throw new InvalidOperationException("界面预览不会保存设置。");
            }
            if (!IsGateConfirmed)
            {
                throw new InvalidOperationException("请先完成首次设置并确认代码目录。");
            }
            DesktopPreferences.LoginEnabled = Login;
            Context.Preferences.NotificationsEnabled = Notifications;
            Context.Preferences.Save();
            Report("设置已保存。");
            return Task.CompletedTask;
        }), () => IsGateConfirmed);
        CheckCommand = new AsyncRelayCommand(() => RunAsync(CheckAsync), () => CanCheckUpdates);
        InstallCommand = new AsyncRelayCommand(() => RunAsync(InstallAsync), () => CanInstall);
        WidenBrowseRootCommand = new AsyncRelayCommand(() => RunAsync(WidenBrowseRootAsync), () => IsGateConfirmed && !Context.Preview);
        TightenBrowseRootCommand = new AsyncRelayCommand(() => RunAsync(TightenBrowseRootAsync), () => IsGateConfirmed && HasWidenedBrowseRoot && !Context.Preview);
        NotifyCommand = new RelayCommand(() => { _ = RunAsync(() => { Context.Notify("Mimi Remote", "服务与更新事件会在这里通知你。"); return Task.CompletedTask; }); });
        OpenSetupCommand = new RelayCommand(() => Context.NavigateRoute(OnboardingNavigationGate.RouteSetup));
        OpenDiagnosticsCommand = new RelayCommand(() => Context.NavigateRoute(OnboardingNavigationGate.RouteDiagnostics));
        ConfirmWorkspaceViaMaintenanceCommand = new AsyncRelayCommand(() => RunAsync(ConfirmWorkspaceViaMaintenanceAsync), () => IsPendingConfirmation);
        OpenMaintenanceDownloadCommand = new RelayCommand(
            () =>
            {
                if (maintenanceFallbackDownloadUrl is { } url && OnboardingCopyCatalog.IsAllowedUrl(url))
                {
                    Context.OpenUrl(url);
                }
            },
            () => HasMaintenanceDownloadFallback);
        context.GateStateChanged += OnGateStateChanged;
        PropertyChanged += (_, args) =>
        {
            if (string.Equals(args.PropertyName, nameof(IsBusy), StringComparison.Ordinal))
            {
                InstallCommand.NotifyCanExecuteChanged();
            }
        };
    }

    protected override async Task RefreshAsync(bool force)
    {
        if (Context.Preview)
        {
            ServiceVersion = (await Context.ReadStatusAsync(force: force, token: Lifetime.Token)).Version;
            return;
        }
        if (Context.HasAgent)
        {
            try
            {
                var report = await Context.ReadPreflightAsync(
                    new OnboardingPreflightOptions
                    {
                        Stage = IsGateConfirmed ? "pair" : "setup",
                        ProgressJson = false,
                        VerifiedConfigured = IsGateConfirmed,
                        VerifiedCapability = Context.VerifiedCapability,
                    },
                    onProgress: null,
                    cancellationToken: Lifetime.Token);
                ScanRoot = report.ScanRoot;
                BrowseRoot = report.BrowseRoot;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception error) when (error is InvalidOperationException or InvalidDataException
                or IOException or TimeoutException or UnauthorizedAccessException or System.ComponentModel.Win32Exception)
            {
                ScanRoot = "";
                BrowseRoot = "";
            }
        }
        if (IsGateConfirmed && Context.HasAgent)
        {
            ServiceVersion = (await Context.ReadStatusAsync(force: force, token: Lifetime.Token)).Version;
        }
    }

    private async Task WidenBrowseRootAsync()
    {
        if (!IsGateConfirmed)
        {
            return;
        }
        if (string.IsNullOrWhiteSpace(ScanRoot))
        {
            await RefreshAsync(force: true);
        }
        if (string.IsNullOrWhiteSpace(ScanRoot))
        {
            throw new InvalidOperationException("无法读取当前代码目录，请刷新后重试。");
        }
        var candidate = await Context.PickFolder();
        if (string.IsNullOrWhiteSpace(candidate))
        {
            return;
        }
        var fullCandidate = Path.GetFullPath(candidate.Trim());
        var confirmed = await Context.Confirm(
            "扩大手机代码浏览范围？",
            $"当前代码目录：{ScanRoot}\n拟授权手机浏览目录：{fullCandidate}\n\n确认后，已配对的手机将能浏览该目录及其子目录中的文件。取消不会影响已有配对和配置。");
        if (!confirmed || !IsGateConfirmed)
        {
            return;
        }
        await Context.ChangeAsync(() => new ModuleCommands(Context.Agent).SetBrowseRootAsync(fullCandidate, preserveAdditionalRoots: true, Lifetime.Token));
        BrowseRoot = fullCandidate;
        Report("浏览目录范围已更新，已有配对保持有效。");
    }

    private async Task TightenBrowseRootAsync()
    {
        var selected = ScanRoot;
        if (!IsGateConfirmed || string.IsNullOrWhiteSpace(selected))
        {
            return;
        }
        var confirmed = await Context.Confirm(
            "恢复最小浏览范围？",
            $"将把手机浏览范围收紧为仅限代码目录：{selected}。已有配对保持有效。");
        if (!confirmed || !IsGateConfirmed)
        {
            return;
        }
        await Context.ChangeAsync(() => new ModuleCommands(Context.Agent).SetBrowseRootAsync(selected, preserveAdditionalRoots: false, Lifetime.Token));
        BrowseRoot = selected;
        Report("已恢复为仅允许浏览所选代码目录。");
    }

    private async Task ConfirmWorkspaceViaMaintenanceAsync()
    {
        if (!IsPendingConfirmation || Context.RunInstallerMaintenance is not { } runMaintenance)
        {
            return;
        }
        SetMaintenanceFallbackUrl(null);
        var result = await runMaintenance(MaintenancePurpose.ConfirmWorkspace, Lifetime.Token);
        SetMaintenanceFallbackUrl(result.FallbackToDownload ? result.DownloadUrl : null);
        if (result.BrokerVerified)
        {
            if (result.PostRunPreflight is { } verifiedPreflight)
            {
                Context.UpdateGateFromPreflight(verifiedPreflight);
                ScanRoot = verifiedPreflight.ScanRoot;
                BrowseRoot = verifiedPreflight.BrowseRoot;
            }
            if (result.PostRunStatus is { } verifiedStatus && !string.IsNullOrWhiteSpace(verifiedStatus.Version))
            {
                ServiceVersion = verifiedStatus.Version;
            }
            else if (result.PostRunPreflight is null)
            {
                await RefreshAsync(force: true);
            }
        }
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
        OnPropertyChanged(nameof(IsGateConfirmed));
        OnPropertyChanged(nameof(IsReadOnlyMode));
        OnPropertyChanged(nameof(IsPendingConfirmation));
        OnPropertyChanged(nameof(GateNotice));
        OnPropertyChanged(nameof(CanInstall));
        SaveCommand.NotifyCanExecuteChanged();
        InstallCommand.NotifyCanExecuteChanged();
        WidenBrowseRootCommand.NotifyCanExecuteChanged();
        TightenBrowseRootCommand.NotifyCanExecuteChanged();
        ConfirmWorkspaceViaMaintenanceCommand.NotifyCanExecuteChanged();
    }

    private async Task CheckAsync()
    {
        if (!CanCheckUpdates)
        {
            return;
        }
        var candidate = WindowsRelease.Decode(await updates.GetStringAsync(WindowsRelease.LatestApi, Lifetime.Token));
        release = Version.Parse(candidate.Version) > Context.Build.Release ? candidate : null;
        OnPropertyChanged(nameof(AvailableVersion));
        OnPropertyChanged(nameof(CanInstall));
        InstallCommand.NotifyCanExecuteChanged();
        Report(release is null ? "已是最新正式版本。" : $"Windows {release.Version} 已发布。");
    }

    private async Task InstallAsync()
    {
        if (!CanCheckUpdates || !IsGateConfirmed || release is not { } selected)
        {
            return;
        }
        if (!await Context.Confirm($"安装 Windows {selected.Version}？", "服务会重启，请先结束正在进行的任务。"))
        {
            return;
        }
        var directory = Path.Combine(Path.GetTempPath(), "mimi-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var installer = Path.Combine(directory, Path.GetFileName(selected.DownloadUrl.AbsolutePath));
        try
        {
            var checksum = await updates.GetStringAsync(selected.ChecksumUrl, Lifetime.Token);
            if (checksum.Length > 4096)
            {
                throw new InvalidDataException("更新校验文件过大。");
            }
            await using (var source = await updates.GetStreamAsync(selected.DownloadUrl, Lifetime.Token))
            await using (var output = File.Create(installer))
            {
                var buffer = new byte[65536];
                long size = 0;
                while (true)
                {
                    var read = await source.ReadAsync(buffer, Lifetime.Token);
                    if (read == 0)
                    {
                        break;
                    }
                    size += read;
                    if (size > 1024L * 1024 * 1024)
                    {
                        throw new InvalidDataException("更新安装包超出预期大小。");
                    }
                    await output.WriteAsync(buffer.AsMemory(0, read), Lifetime.Token);
                }
            }
            using var verified = new FileStream(installer, FileMode.Open, FileAccess.Read, FileShare.Read);
            await WindowsRelease.VerifyHashAsync(installer, checksum, Path.GetFileName(installer), Lifetime.Token);
            await Task.Run(() => InstallerTrust.Verify(installer, Environment.ProcessPath!), Lifetime.Token);
            var start = new System.Diagnostics.ProcessStartInfo(installer) { UseShellExecute = false, CreateNoWindow = true };
            start.ArgumentList.Add("/SILENT");
            start.ArgumentList.Add("/NORESTART");
            System.Diagnostics.Process.Start(start)?.Dispose();
            Context.Quit();
        }
        catch
        {
            if (File.Exists(installer))
            {
                File.Delete(installer);
            }
            throw;
        }
    }

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("MimiRemote-Windows/preview");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    public override void Dispose()
    {
        Context.GateStateChanged -= OnGateStateChanged;
        updates.Dispose();
        base.Dispose();
    }
}
