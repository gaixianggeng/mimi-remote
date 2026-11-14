using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MimiRemote.Core;

namespace MimiRemote.App;

public sealed partial class MainWindow : Window, IDisposable
{
    private readonly AgentClient? client;
    private readonly bool preview;
    private readonly CancellationTokenSource lifetime = new();
    private readonly DispatcherTimer pairingTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private HostStatus? host;
    private TailcatStatus? tailcat;
    private bool busy;
    private bool quitting;
    private bool disposed;
    private string page = "sessions";
    private readonly SessionsPage sessionsPage;
    private readonly DispatcherTimer connectionTimer = new() { Interval = TimeSpan.FromSeconds(3) };
    private bool windowActive;
    private TrayIcon? tray;
    private DateTimeOffset? pairExpiry;
    private Image? pairImage;
    private TextBlock? pairNote;
    private long pairGeneration;

    public MainWindow(bool preview = false)
    {
        this.preview = preview;
        InitializeComponent();
        if (preview)
        {
            var arguments = Environment.GetCommandLineArgs();
            if (arguments.Contains("--debug-dark", StringComparer.Ordinal)) { Root.RequestedTheme = ElementTheme.Dark; }
            else if (arguments.Contains("--debug-light", StringComparer.Ordinal)) { Root.RequestedTheme = ElementTheme.Light; }
        }
        sessionsPage = new SessionsPage(preview);
        SessionsHost.Children.Add(sessionsPage);
        Activated += async (_, args) =>
        {
            windowActive = args.WindowActivationState != WindowActivationState.Deactivated;
            sessionsPage.SetActive(page == "sessions" && windowActive && AppWindow.IsVisible);
            if (windowActive && page == "sessions") { await ExecuteAsync(RefreshAsync); }
        };
        AppWindow.Changed += (_, args) =>
        {
            if (args.DidVisibilityChange) { sessionsPage.SetActive(page == "sessions" && windowActive && AppWindow.IsVisible); }
        };
        connectionTimer.Tick += async (_, _) =>
        {
            if (!preview && page == "connection" && windowActive && AppWindow.IsVisible && !busy)
            {
                await ExecuteAsync(async () =>
                {
                    tailcat = await RequireClient().ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], lifetime.Token);
                    UpdateConnectionControls();
                });
            }
        };
        connectionTimer.Start();
        Title = preview ? "Mimi Remote · 界面预览" : "Mimi Remote";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1040, 760));
        Root.Loaded += (_, _) =>
        {
            var scale = Root.XamlRoot.RasterizationScale;
            var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
            AppWindow.Resize(new Windows.Graphics.SizeInt32(
                Math.Min((int)(1040 * scale), Math.Max(320, area.Width - 48)),
                Math.Min((int)(760 * scale), Math.Max(320, area.Height - 48))));
        };
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "mimi-remote.ico"));
        if (!preview)
        {
            try { client = new AgentClient(AgentClient.FindExecutable()); }
            catch (FileNotFoundException error) { ShowError(error.Message); }
        }
        Closed += (_, _) => Dispose();
        AppWindow.Closing += (_, args) =>
        {
            if (!quitting && tray is not null)
            {
                args.Cancel = true;
                ClearPairing();
                AppWindow.Hide();
            }
        };
        pairingTimer.Tick += (_, _) =>
        {
            if (pairExpiry is not null && DateTimeOffset.UtcNow >= pairExpiry)
            {
                ClearPairing();
                if (pairNote is not null) { pairNote.Text = "二维码已过期，请重新生成。"; }
            }
        };
        pairingTimer.Start();
        if (!preview) { InitializeNotifications(); }
        Navigation.SelectedItem = Navigation.MenuItems.OfType<NavigationViewItem>().First(item => (string)item.Tag ==
            (!preview && (!preferences.SetupCompleted || !File.Exists(DesktopPreferences.ConfigPath)) ? "setup" : "sessions"));
    }

    public void InitializeTray()
    {
        try { tray = new TrayIcon(this, ShowHome, () => ShowPage("pair"), Quit); }
        catch (InvalidOperationException error) { ShowError(error.Message); }
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        lifetime.Cancel();
        pairingTimer.Stop();
        connectionTimer.Stop();
        sessionsPage.Dispose();
        tray?.Dispose();
        DisposeNotifications();
        updates.Dispose();
        lifetime.Dispose();
    }

    private void Quit()
    {
        quitting = true;
        Close();
    }

    public void ShowPage(string destination)
    {
        AppWindow.Show();
        Activate();
        var selected = Navigation.MenuItems.OfType<NavigationViewItem>()
            .FirstOrDefault(item => (string)item.Tag == destination);
        Navigation.SelectedItem = selected ?? Navigation.MenuItems[0];
    }

    public void ShowHome() => ShowPage(!preview && (!preferences.SetupCompleted || !File.Exists(DesktopPreferences.ConfigPath)) ? "setup" : "sessions");

    public void HideToTray()
    {
        if (tray is not null) { AppWindow.Hide(); }
    }

    private async void Navigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item) { return; }
        ClearPairing();
        page = (string)item.Tag;
        sessionsPage.SetActive(page == "sessions" && windowActive && AppWindow.IsVisible);
        PageTitle.Text = (string)item.Content;
        Render();
        await ExecuteAsync(RefreshAsync);
    }

    private async void RefreshClicked(object sender, RoutedEventArgs args) => await ExecuteAsync(RefreshAsync);

    private void ContentHostResized(object sender, SizeChangedEventArgs args) => ContentColumn.Width = args.NewSize.Width;

    private async Task RefreshAsync()
    {
        if (preview)
        {
            host = new HostStatus
            {
                Version = "预览",
                Projects = 4,
                ServiceOk = true,
                ProcessOk = true,
                ModuleStatus = new ModuleStatus { CodexEnabled = true, ClaudeEnabled = true, TailscaleEnabled = true },
                RuntimeStatus = new RuntimeStatus
                {
                    Runtimes = [
                    new RuntimeEntry { Id = "codex", Title = "Codex", Enabled = true, State = "ready",
                        RateLimits = new RuntimeRateLimits { PlanType = "预览", Primary = new RateLimitWindow { UsedPercent = 24, WindowDurationMins = 300 } } },
                    new RuntimeEntry { Id = "claude", Title = "Claude", Enabled = true, State = "ready" }]
                }
            };
            tailcat = new TailcatStatus { Enabled = true, Running = true, Mode = "managed", PairedDeviceCount = 2 };
        }
        else
        {
            if (page == "setup" && !File.Exists(DesktopPreferences.ConfigPath)) { return; }
            var agent = RequireClient();
            host = await agent.ReadAsync<HostStatus>(page == "sessions" ? ["status", "--json"] : ["status", "--json", "--runtime"], lifetime.Token);
            tailcat = null;
            if (host.ServiceOk && page != "sessions")
            {
                try { tailcat = await agent.ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], lifetime.Token); }
                catch (InvalidOperationException error) { ShowError(error.Message); }
            }
        }
        Render();
        if (page == "sessions") { await sessionsPage.RefreshAsync(host); }
    }

    private AgentClient RequireClient() => client ?? throw new InvalidOperationException(
        preview ? "这是界面预览，不会更改电脑服务。" : "未找到电脑服务，请先安装 Mimi Remote。");

    private async Task ExecuteAsync(Func<Task> operation)
    {
        if (busy || disposed) { return; }
        busy = true;
        Progress.Visibility = Visibility.Visible;
        PageScroll.IsEnabled = false;
        Notice.IsOpen = false;
        try { await operation(); }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception error) when (error is InvalidOperationException or IOException or TimeoutException
            or System.Text.Json.JsonException or ArgumentException or System.ComponentModel.Win32Exception
            or System.Net.Http.HttpRequestException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            ShowError(error.Message);
        }
        finally
        {
            busy = false;
            if (!disposed)
            {
                Progress.Visibility = Visibility.Collapsed;
                PageScroll.IsEnabled = true;
            }
        }
    }

    private void ShowError(string message)
    {
        Notice.Severity = InfoBarSeverity.Error;
        Notice.Title = "需要处理";
        Notice.Message = message;
        Notice.IsOpen = true;
    }

    private async Task<bool> ConfirmAsync(string title, string message)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Root.XamlRoot,
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = "继续",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private static TextBlock Text(string text, double size = 14) =>
        new() { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };

    private static StackPanel Row() => new() { Orientation = Orientation.Horizontal, Spacing = 10 };

    private static Border Card(StackPanel contents) => new()
    {
        Style = (Style)Application.Current.Resources["NativeCardStyle"],
        Child = contents,
    };

    private Button Action(string label, Func<Task> callback)
    {
        var button = new Button { Content = label };
        button.Click += async (_, _) => await ExecuteAsync(callback);
        return button;
    }

    private void Render()
    {
        ClearPairing();
        Body.Children.Clear();
        var sessions = page == "sessions";
        ContentColumn.MaxWidth = sessions ? 1120 : 906;
        SessionsHost.Visibility = sessions ? Visibility.Visible : Visibility.Collapsed;
        PageScroll.Visibility = sessions ? Visibility.Collapsed : Visibility.Visible;
        if (sessions) { return; }
        switch (page)
        {
            case "pair": RenderPairing(); break;
            case "setup": RenderSetup(); break;
            case "assistants": RenderAssistants(); break;
            case "settings": RenderSettings(); break;
            case "connection": RenderConnection(); break;
            case "diagnostics": RenderDiagnostics(); break;
            default: RenderOverview(); break;
        }
    }

    private void ClearPairing()
    {
        pairGeneration++;
        pairExpiry = null;
        if (pairImage is not null) { pairImage.Source = null; }
    }
}
