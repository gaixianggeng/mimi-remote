using System.ComponentModel;
using System.Runtime.InteropServices;

namespace MimiRemote.AgentHost;

/// <summary>
/// 用 <c>CREATE_NO_WINDOW | CREATE_SUSPENDED</c> 启动 agentd。挂起是为了先把它绑进
/// Job Object 再放行，否则 agentd 可能在绑定前就派生出子进程。句柄不继承。
/// </summary>
internal sealed class SuspendedProcess : IDisposable
{
    private readonly IntPtr process;
    private readonly IntPtr thread;

    private SuspendedProcess(IntPtr process, IntPtr thread, int processId)
    {
        this.process = process;
        this.thread = thread;
        ProcessId = processId;
    }

    internal int ProcessId { get; }

    internal IntPtr ProcessHandle => process;

    internal static SuspendedProcess? TryStart(string applicationPath, string commandLine, out string error)
    {
        error = string.Empty;

        var startupInfo = new NativeMethods.StartupInfo();
        startupInfo.Cb = Marshal.SizeOf<NativeMethods.StartupInfo>();

        var created = NativeMethods.CreateProcess(
            applicationPath,
            commandLine,
            IntPtr.Zero,
            IntPtr.Zero,
            inheritHandles: false,
            NativeMethods.CreateNoWindow | NativeMethods.CreateSuspended,
            IntPtr.Zero,
            null,
            ref startupInfo,
            out var information);

        if (!created)
        {
            error = "启动 agentd 失败：" + DescribeLastError();
            return null;
        }

        return new SuspendedProcess(information.Process, information.Thread, information.ProcessId);
    }

    internal bool TryResume(out string error)
    {
        error = string.Empty;

        var previous = NativeMethods.ResumeThread(thread);
        if (previous == uint.MaxValue)
        {
            error = "恢复 agentd 运行失败：" + DescribeLastError();
            return false;
        }

        return true;
    }

    internal bool TryWaitForExit(out uint exitCode, out string error)
    {
        exitCode = 0;
        error = string.Empty;

        var wait = NativeMethods.WaitForSingleObject(process, NativeMethods.Infinite);
        if (wait == NativeMethods.WaitFailed)
        {
            error = "等待 agentd 退出失败：" + DescribeLastError();
            return false;
        }

        if (!NativeMethods.GetExitCodeProcess(process, out exitCode))
        {
            error = "读取 agentd 退出码失败：" + DescribeLastError();
            return false;
        }

        return true;
    }

    internal void Terminate()
    {
        NativeMethods.TerminateProcess(process, 1);
    }

    public void Dispose()
    {
        if (thread != IntPtr.Zero)
        {
            NativeMethods.CloseHandle(thread);
        }

        if (process != IntPtr.Zero)
        {
            NativeMethods.CloseHandle(process);
        }
    }

    private static string DescribeLastError()
    {
        var code = Marshal.GetLastWin32Error();
        return new Win32Exception(code).Message + " (0x" + code.ToString("X8") + ")";
    }
}
