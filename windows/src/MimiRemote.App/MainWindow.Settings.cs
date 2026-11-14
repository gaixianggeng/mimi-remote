using System.Diagnostics;
using System.Net.Http;
using Microsoft.UI.Xaml.Controls;
using MimiRemote.Core;

namespace MimiRemote.App;

public sealed partial class MainWindow
{
    private WindowsRelease? availableUpdate;
    private readonly HttpClient updates = CreateUpdateClient();

    private static HttpClient CreateUpdateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("MimiRemote-Windows/1.0");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    private void RenderSettings()
    {
        var startup = new StackPanel { Spacing = 12 };
        startup.Children.Add(Text("登录与通知", 22));
        var login = new ToggleSwitch { Header = "登录后在托盘运行", IsOn = !preview && DesktopPreferences.LoginEnabled, IsEnabled = !preview };
        login.Toggled += (_, _) =>
        {
            try { DesktopPreferences.LoginEnabled = login.IsOn; }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException)
            { Render(); ShowError("无法保存登录启动设置：" + error.Message); }
        };
        startup.Children.Add(login);
        startup.Children.Add(Text("此开关控制客户端窗口和托盘。后台服务由系统独立管理，退出客户端后手机仍可连接。"));
        var notifications = new ToggleSwitch { Header = "允许系统通知", IsOn = preferences.NotificationsEnabled, IsEnabled = !preview };
        notifications.Toggled += (_, _) =>
        {
            preferences.NotificationsEnabled = notifications.IsOn;
            try { preferences.Save(); }
            catch (IOException error) { ShowError("无法保存通知设置：" + error.Message); }
        };
        startup.Children.Add(notifications);
        startup.Children.Add(Action("发送测试通知", () => { SendNotification("Mimi Remote", "需要注意的服务与更新事件会在这里通知你。"); return Task.CompletedTask; }));
        Body.Children.Add(Card(startup));

        var update = new StackPanel { Spacing = 12 };
        update.Children.Add(Text("软件更新", 22));
        update.Children.Add(Text($"当前服务版本：{host?.Version ?? "尚未读取"}"));
        update.Children.Add(Text("只接受官方仓库的正式 Windows 安装包。运行前校验 SHA-256、Windows 信任链和发布者证书；校验失败时不会安装。"));
        update.Children.Add(Action("检查更新", async () =>
        {
            var json = await updates.GetStringAsync(WindowsRelease.LatestApi, lifetime.Token);
            availableUpdate = WindowsRelease.Decode(json);
            var current = typeof(App).Assembly.GetName().Version;
            if (current is not null && Version.Parse(availableUpdate.Version) <= new Version(current.Major, current.Minor, Math.Max(current.Build, 0)))
            {
                availableUpdate = null;
                ShowSuccess("已是最新正式版本", "当前客户端无需更新。");
                return;
            }
            Render();
            ShowSuccess("发现正式版本", $"Windows {availableUpdate.Version} 已发布。请确认版本后选择下载并安装。");
        }));
        if (availableUpdate is { } release)
        {
            update.Children.Add(Text($"可用版本：{release.Version}"));
            update.Children.Add(Action("下载并安装更新", () => InstallUpdateAsync(release)));
        }
        update.Children.Add(Text("未签名预览版无法自动安装更新。签名尚未就绪时，可继续使用当前版本。"));
        Body.Children.Add(Card(update));
    }

    private async Task InstallUpdateAsync(WindowsRelease release)
    {
        if (preview) { throw new InvalidOperationException("界面预览不会安装更新。"); }
        if (!await ConfirmAsync($"安装 Windows {release.Version}？", "服务会重启，手机连接会短暂断开。请先结束正在进行的任务。")) { return; }
        var directory = Path.Combine(Path.GetTempPath(), "mimi-update-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var installer = Path.Combine(directory, Path.GetFileName(release.DownloadUrl.AbsolutePath));
        var checksum = await updates.GetStringAsync(release.ChecksumUrl, lifetime.Token);
        if (checksum.Length > 4096) { throw new InvalidDataException("更新校验文件过大。"); }
        await using (var source = await updates.GetStreamAsync(release.DownloadUrl, lifetime.Token))
        await using (var output = File.Create(installer))
        {
            var buffer = new byte[65536];
            long size = 0;
            int read;
            while ((read = await source.ReadAsync(buffer, lifetime.Token)) > 0)
            {
                size += read;
                if (size > 1024L * 1024 * 1024) { throw new InvalidDataException("更新安装包超过允许大小。"); }
                await output.WriteAsync(buffer.AsMemory(0, read), lifetime.Token);
            }
        }
        // Keep the verified payload open without write/delete sharing through launch.
        using var verified = new FileStream(installer, FileMode.Open, FileAccess.Read, FileShare.Read);
        await WindowsRelease.VerifyHashAsync(installer, checksum, Path.GetFileName(installer), lifetime.Token);
        await Task.Run(() => InstallerTrust.Verify(installer, Environment.ProcessPath!), lifetime.Token);
        var start = new ProcessStartInfo(installer) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("/SILENT");
        start.ArgumentList.Add("/NORESTART");
        Process.Start(start)?.Dispose();
        Quit();
    }
}
