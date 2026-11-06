using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace MimiRemote.App;

public sealed partial class App : Application, IDisposable
{
    private MainWindow? window;
    private AppInstance? instance;
    private bool disposed;

    public App() { InitializeComponent(); }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var preview = Environment.GetCommandLineArgs().Contains("--debug-seed-ui", StringComparer.Ordinal);
        instance = AppInstance.FindOrRegisterForKey(preview ? "MimiRemote.Preview" : "MimiRemote.Native");
        if (!instance.IsCurrent)
        {
            await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs());
            Exit();
            return;
        }
        instance.Activated += (_, activation) =>
        {
            var pair = activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch &&
                launch.Arguments.Contains("--pair", StringComparison.Ordinal);
            window?.DispatcherQueue.TryEnqueue(() => window.ShowPage(pair ? "pair" : "overview"));
        };
        window = new MainWindow(preview);
        window.Closed += (_, _) => Dispose();
        window.Activate();
        // During the preview period the installed Go tray remains the only tray icon.
        if (!preview && System.Diagnostics.Process.GetProcessesByName("mimi-remote-tray").Length == 0)
        {
            window.InitializeTray();
        }
        if (Environment.GetCommandLineArgs().Contains("--pair", StringComparer.Ordinal)) { window.ShowPage("pair"); }
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        window?.Dispose();
        window = null;
    }
}
