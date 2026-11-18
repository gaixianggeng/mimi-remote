using System.ComponentModel;
using System.Runtime.InteropServices;

namespace MimiRemote.AgentHost;

/// <summary>
/// 宿主自持的 Job Object，设置 <c>KILL_ON_JOB_CLOSE</c>。宿主被强杀或崩溃时句柄关闭，
/// Windows 会连带结束 agentd 及其后代，避免计划任务重试时留下孤儿服务进程。
/// </summary>
internal sealed class JobObject : IDisposable
{
    private IntPtr handle;

    private JobObject(IntPtr handle)
    {
        this.handle = handle;
    }

    internal static JobObject? TryCreate(out string error)
    {
        error = string.Empty;

        var handle = NativeMethods.CreateJobObject(IntPtr.Zero, IntPtr.Zero);
        if (handle == IntPtr.Zero)
        {
            error = "创建 Job Object 失败：" + DescribeLastError();
            return null;
        }

        var information = new NativeMethods.JobObjectExtendedLimitInformation();
        information.BasicLimitInformation.LimitFlags = NativeMethods.JobObjectLimitKillOnJobClose;

        if (!NativeMethods.SetInformationJobObject(
                handle,
                NativeMethods.JobObjectExtendedLimitInformationClass,
                ref information,
                (uint)Marshal.SizeOf<NativeMethods.JobObjectExtendedLimitInformation>()))
        {
            error = "配置 Job Object 失败：" + DescribeLastError();
            NativeMethods.CloseHandle(handle);
            return null;
        }

        return new JobObject(handle);
    }

    internal bool TryAssign(IntPtr process, out string error)
    {
        error = string.Empty;

        if (NativeMethods.AssignProcessToJobObject(handle, process))
        {
            return true;
        }

        error = "绑定 agentd 到 Job Object 失败：" + DescribeLastError();
        return false;
    }

    public void Dispose()
    {
        if (handle == IntPtr.Zero)
        {
            return;
        }

        NativeMethods.CloseHandle(handle);
        handle = IntPtr.Zero;
    }

    private static string DescribeLastError()
    {
        var code = Marshal.GetLastWin32Error();
        return new Win32Exception(code).Message + " (0x" + code.ToString("X8") + ")";
    }
}
