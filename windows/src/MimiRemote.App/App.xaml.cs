using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using MimiRemote.Core;

namespace MimiRemote.App;

public sealed partial class App : Application, IDisposable
{
    public static ClientContext Services { get; private set; } = null!;
    private MainWindow? window;
    private AppInstance? instance;
    private bool disposed;

    public App() { InitializeComponent(); }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var arguments = Environment.GetCommandLineArgs();
        var preview = false;
#if DEBUG
        preview = arguments.Contains("--debug-seed-ui", StringComparer.Ordinal);
#endif
        var background = arguments.Contains("--background", StringComparer.Ordinal);
        var legacyTray = System.Diagnostics.Process.GetProcessesByName("mimi-remote-tray").Length > 0;
        if (!preview && !ClientStartup.ShouldLaunch(background, legacyTray)) { Exit(); return; }
        instance = AppInstance.FindOrRegisterForKey(preview ? "MimiRemote.Preview" : "MimiRemote.Native");
        if (!instance.IsCurrent)
        {
            await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs());
            Exit();
            return;
        }
        instance.Activated += (_, activation) =>
        {
            if (activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs backgroundLaunch &&
                backgroundLaunch.Arguments.Contains("--background", StringComparison.Ordinal)) { return; }
            var pair = activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch &&
                launch.Arguments.Contains("--pair", StringComparison.Ordinal);
            window?.DispatcherQueue.TryEnqueue(() => { if (pair) { window.ShowPage("pair"); } else { window.ShowHome(); } });
        };
        Services = new ClientContext(preview);
        window = new MainWindow(Services);
        window.Closed += (_, _) => Dispose();
        // During the preview period the installed Go tray remains the only tray icon.
        if (!preview && !legacyTray)
        {
            window.InitializeTray();
        }
        if (Environment.GetCommandLineArgs().Contains("--pair", StringComparer.Ordinal)) { window.ShowPage("pair"); }
        else if (background) { window.HideToTray(); }
        else { window.Activate(); }
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        window?.Dispose();
        window = null;
    }
}
