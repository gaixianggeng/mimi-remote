using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using MimiRemote.App.Pages;

namespace MimiRemote.App;

public sealed partial class MainWindow : Window, IDisposable
{
    private static readonly Dictionary<string, Type> Routes = new()
    {
        ["sessions"] = typeof(SessionsPage),
        ["overview"] = typeof(OverviewPage),
        ["setup"] = typeof(SetupPage),
        ["pair"] = typeof(PairingPage),
        ["connection"] = typeof(ConnectionPage),
        ["assistants"] = typeof(AssistantsPage),
        ["diagnostics"] = typeof(DiagnosticsPage),
        ["settings"] = typeof(SettingsPage)
    };
    private readonly ClientContext context;
    private readonly HashSet<ClientPage> pages = [];
    private bool active;
    private bool quitting;
    private bool disposed;
    private TrayIcon? tray;
    public MainWindow(ClientContext context)
    {
        this.context = context;
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
        Root.SizeChanged += (_, _) => { if (Root.XamlRoot is not null) { SetMinimumSize(Root.XamlRoot.RasterizationScale); } };
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
        context.PickFolder = PickFolderAsync;
        context.Notify = SendNotification;
        context.Quit = Quit;
        Activated += (_, args) => { active = args.WindowActivationState != WindowActivationState.Deactivated; UpdateActivity(); };
        AppWindow.Changed += (_, args) => { if (args.DidVisibilityChange) { UpdateActivity(); } };
        AppWindow.Closing += (_, args) =>
        {
            if (!quitting && tray is not null) { args.Cancel = true; AppWindow.Hide(); UpdateActivity(); }
        };
        Closed += (_, _) => Dispose();
        if (!context.Preview) { InitializeNotifications(); }
        ShowPage(context.Preview || context.Preferences.SetupCompleted && File.Exists(DesktopPreferences.ConfigPath) ? typeof(SessionsPage) : typeof(SetupPage), false);
    }
    private void SetMinimumSize(double scale)
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        { presenter.PreferredMinimumWidth = (int)(640 * scale); presenter.PreferredMinimumHeight = (int)(560 * scale); }
    }
    public void InitializeTray()
    {
        try { tray = new TrayIcon(ShowHome, () => ShowPage(typeof(PairingPage)), Quit); }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception or System.Runtime.InteropServices.COMException)
        { AppWindow.Show(); Activate(); }
    }
    public void ShowHome() => ShowPage(context.Preview || context.Preferences.SetupCompleted && File.Exists(DesktopPreferences.ConfigPath)
        ? typeof(SessionsPage) : typeof(SetupPage));
    public void ShowPage(string route) => ShowPage(Routes.GetValueOrDefault(route, typeof(SessionsPage)));
    public void ShowPage(Type type) => ShowPage(type, true);
    private void ShowPage(Type type, bool show)
    {
        if (show) { AppWindow.Show(); Activate(); }
        var item = Navigation.MenuItems.OfType<NavigationViewItem>().First(entry => Routes[(string)entry.Tag] == type);
        if (!ReferenceEquals(Navigation.SelectedItem, item)) { Navigation.SelectedItem = item; }
        else if (ContentFrame.CurrentSourcePageType != type) { ContentFrame.Navigate(type); }
    }
    public void HideToTray() { if (tray is not null) { AppWindow.Hide(); UpdateActivity(); } }
    private void Quit() { quitting = true; Close(); }
    private void Navigate(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem item && Routes.TryGetValue((string)item.Tag, out var type) && ContentFrame.CurrentSourcePageType != type)
        { ContentFrame.Navigate(type); }
    }
    private void FrameNavigated(object sender, NavigationEventArgs args)
    {
        if (ContentFrame.Content is ClientPage page) { pages.Add(page); }
        var route = Routes.First(pair => pair.Value == args.SourcePageType).Key;
        var item = Navigation.MenuItems.OfType<NavigationViewItem>().First(entry => (string)entry.Tag == route);
        Navigation.SelectedItem = item;
        PageTitle.Text = (string)item.Content;
        ContentColumn.MaxWidth = args.SourcePageType == typeof(SessionsPage) ? 1120 : 906;
        WindowTitleBar.IsBackButtonEnabled = ContentFrame.CanGoBack;
        UpdateActivity();
    }
    private void BackRequested(TitleBar sender, object args) { if (ContentFrame.CanGoBack) { ContentFrame.GoBack(); } }
    private void ContentHostResized(object sender, SizeChangedEventArgs args) => ContentColumn.Width = args.NewSize.Width;
    private void UpdateActivity()
    {
        if (ContentFrame.Content is ClientPage page) { _ = page.Model.SetActiveAsync(active && AppWindow.IsVisible); }
    }
    private async Task<bool> ConfirmAsync(string title, string message) => await new ContentDialog
    {
        XamlRoot = Root.XamlRoot,
        Title = title,
        Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
        PrimaryButtonText = "继续",
        CloseButtonText = "取消",
        DefaultButton = ContentDialogButton.Close
    }.ShowAsync() == ContentDialogResult.Primary;
    private async Task<string?> PickFolderAsync()
    {
        var picker = new Windows.Storage.Pickers.FolderPicker();
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        return (await picker.PickSingleFolderAsync())?.Path;
    }
    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        foreach (var page in pages) { page.Model.Dispose(); }
        tray?.Dispose();
        DisposeNotifications();
        context.Dispose();
    }
}
