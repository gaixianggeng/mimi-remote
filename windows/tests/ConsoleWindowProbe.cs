using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

// A test-only observer: no installed service, configuration or desktop input is modified.
public sealed class ConsoleWindowProbe : IDisposable
{
    private readonly HashSet<IntPtr> baseline = Snapshot();
    private readonly ConcurrentDictionary<IntPtr, bool> observed = new ConcurrentDictionary<IntPtr, bool>();
    private readonly CancellationTokenSource stop = new CancellationTokenSource();
    private readonly Task worker;
    public int Count { get { return observed.Count; } }

    public ConsoleWindowProbe()
    {
        worker = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                foreach (var handle in Snapshot())
                {
                    if (!baseline.Contains(handle)) observed.TryAdd(handle, true);
                }
                await Task.Delay(10).ConfigureAwait(false);
            }
        });
    }

    public void Dispose()
    {
        stop.Cancel();
        worker.GetAwaiter().GetResult();
        stop.Dispose();
    }

    private static HashSet<IntPtr> Snapshot()
    {
        var result = new HashSet<IntPtr>();
        EnumWindows((handle, _) =>
        {
            if (!IsWindowVisible(handle)) return true;
            var name = new StringBuilder(256);
            GetClassName(handle, name, name.Capacity);
            if (name.ToString() == "ConsoleWindowClass" || name.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS")
                result.Add(handle);
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static Process StartPositiveControl()
    {
        var startup = new StartupInfo();
        startup.Size = Marshal.SizeOf(typeof(StartupInfo));
        ProcessInfo process;
        var executable = System.IO.Path.Combine(Environment.SystemDirectory, "cmd.exe");
        var command = new StringBuilder("\"" + executable + "\" /c ping -n 30 127.0.0.1 >nul");
        if (!CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x10,
            IntPtr.Zero, null, ref startup, out process))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        CloseHandle(process.Thread);
        CloseHandle(process.Process);
        return Process.GetProcessById(process.Id);
    }

    private delegate bool EnumProc(IntPtr handle, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll", EntryPoint = "GetClassNameW", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr handle, StringBuilder text, int length);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int Size;
        public IntPtr Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XCount, YCount, Attribute, Flags;
        public short ShowWindow, ReservedSize;
        public IntPtr ReservedPointer, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo { public IntPtr Process, Thread; public int Id, ThreadId; }
    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string executable, StringBuilder command,
        IntPtr processAttributes, IntPtr threadAttributes, bool inherit, uint flags,
        IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
}
