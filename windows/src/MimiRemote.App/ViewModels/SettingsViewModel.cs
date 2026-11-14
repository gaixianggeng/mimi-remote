using System.Net.Http;
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
    public string ClientVersion => Context.Build.Display;
    public string ServiceVersion { get => serviceVersion; private set => SetProperty(ref serviceVersion, value); }
    public bool Login { get => login; set => SetProperty(ref login, value); }
    public bool Notifications { get => notifications; set => SetProperty(ref notifications, value); }
    public bool CanCheckUpdates => Context.Build.CanCheckUpdates && !Context.Preview;
    public string UpdateNote => CanCheckUpdates ? "仅安装通过摘要、Windows 信任链和发布者证书校验的正式版本。" : "开发预览，自动更新将在正式安装版启用。";
    public string AvailableVersion => release is null ? "" : $"可用版本：{release.Version}";
    public bool CanInstall => release is not null && CanCheckUpdates && !IsBusy;
    public IAsyncRelayCommand SaveCommand { get; }
    public IAsyncRelayCommand CheckCommand { get; }
    public IAsyncRelayCommand InstallCommand { get; }
    public IRelayCommand NotifyCommand { get; }
    public SettingsViewModel(ClientContext context) : base(context)
    {
        login = !context.Preview && DesktopPreferences.LoginEnabled;
        notifications = context.Preferences.NotificationsEnabled;
        SaveCommand = new AsyncRelayCommand(() => RunAsync(() =>
        {
            if (Context.Preview) { throw new InvalidOperationException("界面预览不会保存设置。"); }
            DesktopPreferences.LoginEnabled = Login;
            Context.Preferences.NotificationsEnabled = Notifications;
            Context.Preferences.Save(); Report("设置已保存。"); return Task.CompletedTask;
        }));
        CheckCommand = new AsyncRelayCommand(() => RunAsync(CheckAsync), () => CanCheckUpdates);
        InstallCommand = new AsyncRelayCommand(() => RunAsync(InstallAsync), () => CanInstall);
        NotifyCommand = new RelayCommand(() => { _ = RunAsync(() => { Context.Notify("Mimi Remote", "服务与更新事件会在这里通知你。"); return Task.CompletedTask; }); });
        PropertyChanged += (_, args) => { if (args.PropertyName == nameof(IsBusy)) { InstallCommand.NotifyCanExecuteChanged(); } };
    }
    protected override async Task RefreshAsync(bool force)
    {
        if (Context.Preview || File.Exists(DesktopPreferences.ConfigPath))
        { ServiceVersion = (await Context.ReadStatusAsync(force: force, token: Lifetime.Token)).Version; }
    }
    private async Task CheckAsync()
    {
        if (!CanCheckUpdates) { return; }
        var candidate = WindowsRelease.Decode(await updates.GetStringAsync(WindowsRelease.LatestApi, Lifetime.Token));
        release = Version.Parse(candidate.Version) > Context.Build.Release ? candidate : null;
        OnPropertyChanged(nameof(AvailableVersion)); OnPropertyChanged(nameof(CanInstall)); InstallCommand.NotifyCanExecuteChanged();
        Report(release is null ? "已是最新正式版本。" : $"Windows {release.Version} 已发布。");
    }
    private async Task InstallAsync()
    {
        if (!CanCheckUpdates || release is not { } selected) { return; }
        if (!await Context.Confirm($"安装 Windows {selected.Version}？", "服务会重启，手机连接会短暂断开。请先结束正在进行的任务。")) { return; }
        var directory = Path.Combine(Path.GetTempPath(), "mimi-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var installer = Path.Combine(directory, Path.GetFileName(selected.DownloadUrl.AbsolutePath));
        try
        {
            var checksum = await updates.GetStringAsync(selected.ChecksumUrl, Lifetime.Token);
            if (checksum.Length > 4096) { throw new InvalidDataException("更新校验文件过大。"); }
            await using (var source = await updates.GetStreamAsync(selected.DownloadUrl, Lifetime.Token))
            await using (var output = File.Create(installer))
            {
                var buffer = new byte[65536]; long size = 0;
                while (true)
                {
                    var read = await source.ReadAsync(buffer, Lifetime.Token);
                    if (read == 0) { break; }
                    size += read;
                    if (size > 1024L * 1024 * 1024) { throw new InvalidDataException("更新安装包超出预期大小。"); }
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
        catch { if (File.Exists(installer)) { File.Delete(installer); } throw; }
    }
    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("MimiRemote-Windows/preview");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json"); return client;
    }
    public override void Dispose() { updates.Dispose(); base.Dispose(); }
}
