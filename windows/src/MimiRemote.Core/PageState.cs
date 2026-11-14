using CommunityToolkit.Mvvm.ComponentModel;

namespace MimiRemote.Core;

/// <summary>State owned by one page or operation, never by the application window.</summary>
public class PageState : ObservableObject
{
    private bool busy;
    private string notice = "";
    private bool noticeOpen;
    private bool failed;
    private TaskCompletionSource? idle;
    public Task WhenIdle => idle?.Task ?? Task.CompletedTask;
    public bool IsBusy { get => busy; private set { if (SetProperty(ref busy, value)) { OnPropertyChanged(nameof(IsIdle)); } } }
    public bool IsIdle => !IsBusy;
    public string Notice { get => notice; private set => SetProperty(ref notice, value); }
    public bool NoticeOpen { get => noticeOpen; set => SetProperty(ref noticeOpen, value); }
    public bool Failed { get => failed; private set => SetProperty(ref failed, value); }

    public void Report(string message, bool error = false)
    {
        Notice = message;
        Failed = error;
        NoticeOpen = true;
    }

    public async Task RunAsync(Func<Task> operation)
    {
        if (IsBusy) { return; }
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        idle = completion;
        IsBusy = true;
        try { await operation(); }
        catch (OperationCanceledException) { }
        catch (Exception error) when (error is InvalidOperationException or IOException or TimeoutException or ArgumentException
            or System.Text.Json.JsonException or System.Net.Http.HttpRequestException or System.Net.WebSockets.WebSocketException
            or UnauthorizedAccessException or System.Security.SecurityException or System.ComponentModel.Win32Exception or System.Runtime.InteropServices.COMException)
        { Report(error.Message, true); }
        finally { IsBusy = false; completion.TrySetResult(); }
    }
}

public static class ClientStartup
{
    // The installed legacy tray cannot restore a hidden native preview. Leave ownership with it.
    public static bool ShouldLaunch(bool background, bool legacyTrayRunning) => !background || !legacyTrayRunning;
}

public sealed record ClientBuild(string Display, Version? Release)
{
    public bool CanCheckUpdates => Release is not null;
    public static ClientBuild Parse(string? version)
    {
        var value = version ?? "";
        var parts = value.Split('.');
        var formal = parts.Length == 3 && parts.All(part => part.Length > 0 && part.All(char.IsAsciiDigit))
            && Version.TryParse(value, out var parsed) ? parsed : null;
        return new(value.Length == 0 ? "开发预览" : value, formal);
    }
}
