using System.Runtime.InteropServices;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace MimiRemote.App;

public sealed partial class MainWindow
{
    private bool notificationsRegistered;
    private readonly Microsoft.UI.Xaml.DispatcherTimer healthTimer = new() { Interval = TimeSpan.FromSeconds(20) };
    private readonly System.Net.Http.HttpClient health = new() { Timeout = TimeSpan.FromSeconds(4) };
    private bool probing;
    private int missedHealthChecks;

    private void InitializeNotifications()
    {
        try
        {
            AppNotificationManager.Default.NotificationInvoked += NotificationInvoked;
            AppNotificationManager.Default.Register();
            notificationsRegistered = true;
            healthTimer.Tick += async (_, _) => await ProbeHealthAsync();
            healthTimer.Start();
        }
        catch (COMException) { notificationsRegistered = false; }
    }

    private void NotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) =>
        DispatcherQueue.TryEnqueue(() => ShowPage("overview"));

    private void SendNotification(string title, string message)
    {
        if (!context.Preferences.NotificationsEnabled) { throw new InvalidOperationException("请先允许系统通知。"); }
        if (!notificationsRegistered) { throw new InvalidOperationException("系统通知暂不可用，请检查 Windows 通知设置。"); }
        AppNotificationManager.Default.Show(new AppNotificationBuilder().AddText(title).AddText(message).BuildNotification());
    }

    private void DisposeNotifications()
    {
        healthTimer.Stop();
        health.Dispose();
        if (context.Preview) { return; }
        AppNotificationManager.Default.NotificationInvoked -= NotificationInvoked;
        if (notificationsRegistered) { AppNotificationManager.Default.Unregister(); }
    }

    private async Task ProbeHealthAsync()
    {
        var host = context.LastStatus;
        if (probing || disposed || host?.ServiceOk != true || !Uri.TryCreate(host.Endpoint, UriKind.Absolute, out var endpoint)) { return; }
        probing = true;
        try
        {
            using var response = await health.GetAsync(new Uri($"http://127.0.0.1:{endpoint.Port}/healthz"));
            if (response.IsSuccessStatusCode) { missedHealthChecks = 0; }
            else { missedHealthChecks++; }
        }
        catch (Exception error) when (error is System.Net.Http.HttpRequestException or OperationCanceledException) { missedHealthChecks++; }
        finally { probing = false; }
        if (missedHealthChecks == 2 && context.Preferences.NotificationsEnabled && !disposed)
        {
            try { SendNotification("电脑服务暂时不可用", "手机连接可能中断。打开 Mimi Remote 刷新状态或运行诊断。"); }
            catch (Exception error) when (error is COMException or InvalidOperationException) { }
        }
    }
}
