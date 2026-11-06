using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace MimiRemote.App;

/// <summary>Owns one notification icon, including Explorer restart recovery.</summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly nint window;
    private readonly SubclassProc callback;
    private readonly Action show;
    private readonly Action pair;
    private readonly Action quit;
    private readonly uint taskbarCreated;
    private NotifyIconData data;
    private bool disposed;

    internal TrayIcon(Window owner, Action show, Action pair, Action quit)
    {
        this.show = show;
        this.pair = pair;
        this.quit = quit;
        window = WinRT.Interop.WindowNative.GetWindowHandle(owner);
        callback = WindowProcedure;
        taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        data = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(),
            Window = window,
            Id = 1,
            Flags = 1 | 2 | 4,
            CallbackMessage = 0x8001,
            Icon = LoadImage(0, Path.Combine(AppContext.BaseDirectory, "mimi-remote.ico"), 1, 0, 0, 0x10 | 0x40),
            Tip = "Mimi Remote",
            Info = "",
            InfoTitle = "",
        };
        if (!SetWindowSubclass(window, callback, 1, 0) || !ShellNotifyIcon(0, ref data))
        {
            Dispose();
            throw new InvalidOperationException("无法创建托盘图标，请保持窗口打开。");
        }
    }

    private nint WindowProcedure(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint reference)
    {
        if (message == taskbarCreated) { ShellNotifyIcon(0, ref data); }
        if (message == 0x8001)
        {
            if ((uint)lParam is 0x202 or 0x203) { show(); }
            if ((uint)lParam == 0x205)
            {
                var menu = CreatePopupMenu();
                try
                {
                    AppendMenu(menu, 0, 1, "打开 Mimi Remote");
                    AppendMenu(menu, 0, 2, "连接手机");
                    AppendMenu(menu, 0x800, 0, "");
                    AppendMenu(menu, 0, 3, "退出客户端（服务继续运行）");
                    GetCursorPos(out var point);
                    SetForegroundWindow(window);
                    var command = TrackPopupMenu(menu, 0x100 | 0x2, point.X, point.Y, 0, window, 0);
                    if (command == 1) { show(); }
                    if (command == 2) { pair(); }
                    if (command == 3) { quit(); }
                }
                finally { DestroyMenu(menu); }
            }
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        ShellNotifyIcon(2, ref data);
        RemoveWindowSubclass(window, callback, 1);
        if (data.Icon != 0) { DestroyIcon(data.Icon); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size;
        public nint Window;
        public uint Id, Flags, CallbackMessage;
        public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags;
        public Guid Guid;
        public nint BalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }
    private delegate nint SubclassProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint reference);

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll", EntryPoint = "RegisterWindowMessageW", CharSet = CharSet.Unicode)]
    private static extern uint RegisterWindowMessage(string message);
    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode)]
    private static extern nint LoadImage(nint instance, string name, uint type, int x, int y, uint flags);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll")]
    private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", EntryPoint = "AppendMenuW", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(nint menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")]
    private static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint hwnd, nint rect);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint hwnd);
}
