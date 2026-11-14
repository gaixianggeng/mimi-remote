using CommunityToolkit.Mvvm.Input;
using H.NotifyIcon;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace MimiRemote.App;

/// <summary>Explorer recovery and a themed WinUI menu, including while the main window is hidden.</summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly TaskbarIcon icon;
    internal TrayIcon(Action show, Action pair, Action quit)
    {
        var menu = new MenuFlyout();
        menu.Items.Add(new MenuFlyoutItem { Text = "打开 Mimi Remote", Command = new RelayCommand(show) });
        menu.Items.Add(new MenuFlyoutItem { Text = "连接手机", Command = new RelayCommand(pair) });
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(new MenuFlyoutItem { Text = "退出客户端（服务继续运行）", Command = new RelayCommand(quit) });
        icon = new TaskbarIcon
        {
            ToolTipText = "Mimi Remote",
            IconSource = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "mimi-remote.ico"))),
            LeftClickCommand = new RelayCommand(show),
            ContextFlyout = menu,
            ContextMenuMode = ContextMenuMode.SecondWindow,
        };
        icon.ForceCreate(enablesEfficiencyMode: false);
        if (!icon.IsCreated) { icon.Dispose(); throw new InvalidOperationException("无法创建托盘图标，请保持窗口打开。"); }
    }
    public void Dispose() => icon.Dispose();
}
