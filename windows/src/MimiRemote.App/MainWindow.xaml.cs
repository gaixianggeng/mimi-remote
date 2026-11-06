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
    private string page = "overview";
    private TrayIcon? tray;
    private DateTimeOffset? pairExpiry;
    private Image? pairImage;
    private TextBlock? pairNote;
    private long pairGeneration;

    public MainWindow(bool preview = false)
    {
        this.preview = preview;
        InitializeComponent();
        Title = preview ? "Mimi Remote · 界面预览" : "Mimi Remote";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1040, 760));
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
        Navigation.SelectedItem = Navigation.MenuItems[0];
    }

    public void InitializeTray()
    {
        try { tray = new TrayIcon(this, () => ShowPage("overview"), () => ShowPage("pair"), Quit); }
        catch (InvalidOperationException error) { ShowError(error.Message); }
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        lifetime.Cancel();
        pairingTimer.Stop();
        tray?.Dispose();
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

    private async void Navigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is not NavigationViewItem item) { return; }
        ClearPairing();
        page = (string)item.Tag;
        PageTitle.Text = (string)item.Content;
        Render();
        await ExecuteAsync(RefreshAsync);
    }

    private async void RefreshClicked(object sender, RoutedEventArgs args) => await ExecuteAsync(RefreshAsync);

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
                RuntimeStatus = new RuntimeStatus
                {
                    Runtimes = [
                    new RuntimeEntry { Id = "codex", Title = "Codex", Enabled = true, State = "ready" },
                    new RuntimeEntry { Id = "claude", Title = "Claude", Enabled = true, State = "ready" }]
                }
            };
            tailcat = new TailcatStatus { Enabled = true, Running = true, Mode = "managed", PairedDeviceCount = 2 };
        }
        else
        {
            var agent = RequireClient();
            host = await agent.ReadAsync<HostStatus>(["status", "--json", "--runtime"], lifetime.Token);
            tailcat = null;
            if (host.ServiceOk)
            {
                try { tailcat = await agent.ReadAsync<TailcatStatus>(["tailcat", "status", "--json"], lifetime.Token); }
                catch (InvalidOperationException error) { ShowError(error.Message); }
            }
        }
        Render();
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
            or System.Text.Json.JsonException or ArgumentException or System.ComponentModel.Win32Exception)
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
        switch (page)
        {
            case "pair": RenderPairing(); break;
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
