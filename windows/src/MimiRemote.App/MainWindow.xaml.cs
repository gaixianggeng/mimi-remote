using System.Diagnostics;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using MimiRemote.App.Pages;
using MimiRemote.Core;
using Windows.ApplicationModel.DataTransfer;

namespace MimiRemote.App;

public sealed partial class MainWindow : Window, IDisposable
{
    private static readonly Dictionary<string, Type> Routes = new(StringComparer.Ordinal)
    {
        [OnboardingNavigationGate.RouteSessions] = typeof(SessionsPage),
        [OnboardingNavigationGate.RouteOverview] = typeof(OverviewPage),
        [OnboardingNavigationGate.RouteSetup] = typeof(SetupPage),
        [OnboardingNavigationGate.RoutePair] = typeof(PairingPage),
        [OnboardingNavigationGate.RouteConnection] = typeof(ConnectionPage),
        [OnboardingNavigationGate.RouteAssistants] = typeof(AssistantsPage),
        [OnboardingNavigationGate.RouteDiagnostics] = typeof(DiagnosticsPage),
        [OnboardingNavigationGate.RouteSettings] = typeof(SettingsPage),
    };

    private static readonly Dictionary<Type, string> RouteByPageType = Routes.ToDictionary(pair => pair.Value, pair => pair.Key);

    private readonly ClientContext context;
    private readonly HashSet<ClientPage> pages = [];
    private readonly CancellationTokenSource gateRefreshCts = new();
    private bool pendingPairActivation;
    private bool active;
    private bool quitting;
    private bool disposed;
    private TrayIcon? tray;

    public MainWindow(ClientContext context, bool initialPairRequested = false)
    {
        this.context = context;
        pendingPairActivation = initialPairRequested;
        InitializeComponent();
        Title = "Mimi Remote";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(WindowTitleBar);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "mimi-remote.ico"));
        Root.Loaded += (_, _) =>
        {
            var scale = Root.XamlRoot.RasterizationScale;
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
            AppWindow.Resize(new Windows.Graphics.SizeInt32(Math.Min((int)(1040 * scale), area.Width - 48), Math.Min((int)(760 * scale), area.Height - 48)));
            SetMinimumSize(scale);
        };
        Root.SizeChanged += (_, _) =>
        {
            if (Root.XamlRoot is not null)
            {
                SetMinimumSize(Root.XamlRoot.RasterizationScale);
            }
        };
#if DEBUG
        if (context.Preview)
        {
            var args = Environment.GetCommandLineArgs();
            Root.RequestedTheme = args.Contains("--debug-dark", StringComparer.Ordinal) ? ElementTheme.Dark
                : args.Contains("--debug-light", StringComparer.Ordinal) ? ElementTheme.Light : ElementTheme.Default;
        }
#endif
        context.Confirm = ConfirmAsync;
        context.Navigate = ShowPage;
        context.NavigateRoute = ShowPage;
        context.PickFolder = PickFolderAsync;
        context.PickFile = PickFileAsync;
        context.OpenUrl = OpenAllowedUrl;
        context.OpenSettings = OpenAllowedSettings;
        context.CopyToClipboard = CopyTextToClipboard;
        context.Notify = SendNotification;
        context.Quit = Quit;
        context.GateStateChanged += OnGateStateChanged;
        Activated += (_, args) =>
        {
            active = args.WindowActivationState != WindowActivationState.Deactivated;
            UpdateActivity();
        };
        AppWindow.Changed += (_, args) =>
        {
            if (args.DidVisibilityChange)
            {
                UpdateActivity();
            }
        };
        AppWindow.Closing += (_, args) =>
        {
            if (!quitting && tray is not null)
            {
                args.Cancel = true;
                AppWindow.Hide();
                UpdateActivity();
            }
        };
        Closed += (_, _) => Dispose();
        if (!context.Preview)
        {
            InitializeNotifications();
        }
        ApplyGateToNavigation(context.GateState);
        ShowPage(OnboardingNavigationGate.ResolveActivationRoute(context.GateState, pendingPairActivation), show: false);
        if (!context.Preview)
        {
            _ = InitializeGateAsync();
        }
    }

    private async Task InitializeGateAsync()
    {
        var resolved = await context.RefreshGateAsync(gateRefreshCts.Token);
        if (disposed)
        {
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            if (disposed)
            {
                return;
            }
            ApplyGateToNavigation(resolved);
            if (resolved == OnboardingGateState.Confirmed)
            {
                var target = OnboardingNavigationGate.ResolveActivationRoute(resolved, pendingPairActivation);
                pendingPairActivation = false;
                if (ContentFrame.CurrentSourcePageType == typeof(SetupPage))
                {
                    ShowPage(target, show: false);
                }
            }
        });
    }

    private void OnGateStateChanged(object? sender, OnboardingGateState state)
    {
        if (disposed)
        {
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            if (disposed)
            {
                return;
            }
            ApplyGateToNavigation(state);
            if (ContentFrame.CurrentSourcePageType is { } currentType
                && RouteByPageType.TryGetValue(currentType, out var currentRoute)
                && !OnboardingNavigationGate.IsRouteAllowed(state, currentRoute))
            {
                ContentFrame.BackStack.Clear();
                ShowPage(OnboardingNavigationGate.HomeRoute(state), show: false);
            }
        });
    }

    private void ApplyGateToNavigation(OnboardingGateState state)
    {
        foreach (var item in Navigation.MenuItems.OfType<NavigationViewItem>())
        {
            if (item.Tag is string tag)
            {
                item.IsEnabled = OnboardingNavigationGate.IsRouteAllowed(state, tag);
            }
        }
        if (state == OnboardingGateState.Confirmed)
        {
            GateBanner.IsOpen = false;
            return;
        }
        GateBanner.Severity = state == OnboardingGateState.RecoveryLocked
            ? InfoBarSeverity.Error
            : InfoBarSeverity.Warning;
        GateBanner.Message = OnboardingNavigationGate.DescribeState(state);
        GateActionButton.Content = state == OnboardingGateState.RecoveryLocked ? "查看诊断与恢复" : "打开首次设置";
        GateBanner.IsOpen = true;
    }

    private void GateActionClicked(object sender, RoutedEventArgs args)
    {
        var route = context.GateState == OnboardingGateState.RecoveryLocked
            ? OnboardingNavigationGate.RouteDiagnostics
            : OnboardingNavigationGate.RouteSetup;
        ShowPage(route, show: false);
    }

    private void SetMinimumSize(double scale)
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(640 * scale);
            presenter.PreferredMinimumHeight = (int)(560 * scale);
        }
    }

    public void InitializeTray()
    {
        try
        {
            tray = new TrayIcon(
                () => HandleActivation(pairRequested: false),
                () => HandleActivation(pairRequested: true),
                Quit);
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or System.Runtime.InteropServices.COMException)
        {
            AppWindow.Show();
            Activate();
        }
    }

    public void HandleActivation(bool pairRequested)
    {
        if (pairRequested && context.GateState != OnboardingGateState.Confirmed)
        {
            pendingPairActivation = true;
        }
        var route = OnboardingNavigationGate.ResolveActivationRoute(context.GateState, pairRequested);
        ShowPage(route, show: true);
    }

    public void ShowHome() => HandleActivation(pairRequested: false);

    public void ShowPage(string route) => ShowPage(route, show: true);

    public void ShowPage(Type type)
    {
        var route = RouteByPageType.GetValueOrDefault(type, OnboardingNavigationGate.RouteSessions);
        ShowPage(route, show: true);
    }

    private void ShowPage(string route, bool show)
    {
        var allowedRoute = OnboardingNavigationGate.ResolveRoute(context.GateState, route);
        var type = Routes[allowedRoute];
        if (show)
        {
            AppWindow.Show();
            Activate();
        }
        var item = Navigation.MenuItems.OfType<NavigationViewItem>().First(entry => string.Equals((string)entry.Tag, allowedRoute, StringComparison.Ordinal));
        if (!ReferenceEquals(Navigation.SelectedItem, item))
        {
            Navigation.SelectedItem = item;
        }
        else if (ContentFrame.CurrentSourcePageType != type)
        {
            ContentFrame.Navigate(type);
        }
    }

    public void HideToTray()
    {
        if (tray is not null)
        {
            AppWindow.Hide();
            UpdateActivity();
        }
    }

    private void Quit()
    {
        quitting = true;
        Close();
    }

    private void Navigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item && item.Tag is string tag)
        {
            var allowedRoute = OnboardingNavigationGate.ResolveRoute(context.GateState, tag);
            var type = Routes[allowedRoute];
            if (!string.Equals(allowedRoute, tag, StringComparison.Ordinal))
            {
                ShowPage(allowedRoute, show: false);
                return;
            }
            if (ContentFrame.CurrentSourcePageType != type)
            {
                ContentFrame.Navigate(type);
            }
        }
    }

    private void FrameNavigated(object sender, NavigationEventArgs args)
    {
        if (ContentFrame.Content is ClientPage page)
        {
            pages.Add(page);
        }
        var route = RouteByPageType[args.SourcePageType];
        var item = Navigation.MenuItems.OfType<NavigationViewItem>().First(entry => string.Equals((string)entry.Tag, route, StringComparison.Ordinal));
        Navigation.SelectedItem = item;
        PageTitle.Text = (string)item.Content;
        ContentColumn.MaxWidth = args.SourcePageType == typeof(SessionsPage) ? 1120 : 906;
        WindowTitleBar.IsBackButtonEnabled = ContentFrame.CanGoBack;
        UpdateActivity();
    }

    private void BackRequested(TitleBar sender, object args)
    {
        if (!ContentFrame.CanGoBack)
        {
            return;
        }
        var previous = ContentFrame.BackStack.LastOrDefault();
        if (previous is not null
            && RouteByPageType.TryGetValue(previous.SourcePageType, out var previousRoute)
            && !OnboardingNavigationGate.IsRouteAllowed(context.GateState, previousRoute))
        {
            ContentFrame.BackStack.Clear();
            WindowTitleBar.IsBackButtonEnabled = false;
            return;
        }
        ContentFrame.GoBack();
    }

    private void ContentHostResized(object sender, SizeChangedEventArgs args) => ContentColumn.Width = args.NewSize.Width;

    private void UpdateActivity()
    {
        if (ContentFrame.Content is ClientPage page)
        {
            _ = page.Model.SetActiveAsync(active && AppWindow.IsVisible);
        }
    }

    private async Task<bool> ConfirmAsync(string title, string message) => await new ContentDialog
    {
        XamlRoot = Root.XamlRoot,
        Title = title,
        Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
        PrimaryButtonText = "继续",
        CloseButtonText = "取消",
        DefaultButton = ContentDialogButton.Close,
    }.ShowAsync() == ContentDialogResult.Primary;

    private async Task<string?> PickFolderAsync()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        return (await picker.PickSingleFolderAsync())?.Path;
    }

    private async Task<string?> PickFileAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        picker.FileTypeFilter.Add(".exe");
        picker.FileTypeFilter.Add(".cmd");
        picker.FileTypeFilter.Add(".bat");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        return (await picker.PickSingleFileAsync())?.Path;
    }

    private static void OpenAllowedUrl(string url)
    {
        if (!OnboardingCopyCatalog.IsAllowedUrl(url))
        {
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }
    }

    private void OpenAllowedSettings(string target)
    {
        if (!OnboardingCopyCatalog.IsAllowedSettingsTarget(target))
        {
            return;
        }
        switch (target)
        {
            case "windows_network_profile":
                LaunchSystemSettingsUri("ms-settings:network-status");
                break;
            case "windows_firewall":
                LaunchSystemSettingsUri("windowsdefender://network");
                break;
            case "date_time":
                LaunchSystemSettingsUri("ms-settings:dateandtime");
                break;
            case "connections":
                ShowPage(OnboardingNavigationGate.RoutePair, show: false);
                break;
            case "assistants":
                ShowPage(OnboardingNavigationGate.RouteAssistants, show: false);
                break;
            case "host_recovery":
                ShowPage(OnboardingNavigationGate.RouteDiagnostics, show: false);
                break;
            case "managed_connection":
                ShowPage(OnboardingNavigationGate.RouteConnection, show: false);
                break;
        }
    }

    private static void LaunchSystemSettingsUri(string uri)
    {
        try
        {
            Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }
    }

    private static bool CopyTextToClipboard(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }
        try
        {
            var package = new DataPackage();
            package.SetText(text);
            Clipboard.SetContent(package);
            Clipboard.Flush();
            return true;
        }
        catch (Exception error) when (error is InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            return false;
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        context.GateStateChanged -= OnGateStateChanged;
        gateRefreshCts.Cancel();
        gateRefreshCts.Dispose();
        foreach (var page in pages)
        {
            page.Model.Dispose();
        }
        tray?.Dispose();
        DisposeNotifications();
        context.Dispose();
    }
}
