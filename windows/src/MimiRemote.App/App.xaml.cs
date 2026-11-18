using Microsoft.UI.Xaml;
using Microsoft.UI.Dispatching;
using Microsoft.Windows.AppLifecycle;
using MimiRemote.Core;

namespace MimiRemote.App;

public sealed partial class App : Application, IDisposable
{
    public static ClientContext Services { get; private set; } = null!;
    private MainWindow? window;
    private AppInstance? instance;
    private Mutex? trayOwnership;
    private EventWaitHandle? shutdownEvent;
    private RegisteredWaitHandle? shutdownRegistration;
    private FileSystemWatcher? legacyTrayWatcher;
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
        var installation = preview ? null : DesktopInstallation.Find();
        if (installation?.LegacyTrayExists == true || !ClientStartup.ShouldLaunch(background, installation is not null)) { Exit(); return; }
        instance = AppInstance.FindOrRegisterForKey(installation is null ? "MimiRemote.Preview" : "MimiRemote.Installed");
        if (!instance.IsCurrent)
        {
            await instance.RedirectActivationToAsync(AppInstance.GetCurrent().GetActivatedEventArgs());
            Exit();
            return;
        }
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        instance.Activated += (_, activation) =>
        {
            if (activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs backgroundLaunch &&
                backgroundLaunch.Arguments.Contains("--background", StringComparison.Ordinal)) { return; }
            var pair = activation.Data is Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch &&
                launch.Arguments.Contains("--pair", StringComparison.Ordinal);
            dispatcher.TryEnqueue(() => { if (pair) { window?.ShowPage("pair"); } else { window?.ShowHome(); } });
        };
        if (installation is not null)
        {
            // The old Go tray uses the existence of this mutex as its single-instance check.
            trayOwnership = new Mutex(false, DesktopInstallation.TrayMutexName, out var created);
            if (!created) { Dispose(); Exit(); return; }
        }
        Services = new ClientContext(preview) { Installation = installation };
        window = new MainWindow(Services);
        window.Closed += (_, _) => Dispose();
        if (installation is not null)
        {
            shutdownEvent = new EventWaitHandle(false, EventResetMode.AutoReset, DesktopInstallation.ShutdownEventName);
            shutdownRegistration = ThreadPool.RegisterWaitForSingleObject(shutdownEvent,
                (_, _) => dispatcher.TryEnqueue(() => window?.Quit()), null, Timeout.Infinite, executeOnlyOnce: true);
            WatchForLegacyTray(installation, window);
            if (installation.LegacyTrayExists) { window.Quit(); return; }
            window.InitializeTray();
        }
        if (Environment.GetCommandLineArgs().Contains("--pair", StringComparer.Ordinal)) { window.ShowPage("pair"); }
        else if (background) { window.HideToTray(); }
        else { window.Activate(); }
    }

    private void WatchForLegacyTray(DesktopInstallation installation, MainWindow target)
    {
        // Older installers leave app\ alone but restore the legacy executable at the root.
        void Check() => target.DispatcherQueue.TryEnqueue(() =>
        {
            if (!disposed && installation.LegacyTrayExists) { target.Quit(); }
        });
        legacyTrayWatcher = new FileSystemWatcher(installation.DirectoryPath, DesktopInstallation.LegacyTrayName)
        {
            NotifyFilter = NotifyFilters.FileName
        };
        legacyTrayWatcher.Created += (_, _) => Check();
        legacyTrayWatcher.Renamed += (_, _) => Check();
        legacyTrayWatcher.Error += (_, _) => Check();
        legacyTrayWatcher.EnableRaisingEvents = true;
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        legacyTrayWatcher?.Dispose();
        shutdownRegistration?.Unregister(null);
        shutdownEvent?.Dispose();
        window?.Dispose();
        window = null;
        trayOwnership?.Dispose();
    }
}
