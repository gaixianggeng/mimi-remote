using System.Runtime.InteropServices;

namespace MimiRemote.AgentHost;

internal static partial class NativeMethods
{
    internal const uint CreateSuspended = 0x00000004;
    internal const uint CreateNoWindow = 0x08000000;
    internal const uint Infinite = 0xFFFFFFFF;
    internal const uint WaitObject0 = 0x00000000;
    internal const uint WaitFailed = 0xFFFFFFFF;

    internal const uint JobObjectLimitKillOnJobClose = 0x00002000;
    internal const int JobObjectExtendedLimitInformationClass = 9;

    [StructLayout(LayoutKind.Sequential)]
    internal struct StartupInfo
    {
        internal int Cb;
        internal IntPtr Reserved;
        internal IntPtr Desktop;
        internal IntPtr Title;
        internal int X;
        internal int Y;
        internal int XSize;
        internal int YSize;
        internal int XCountChars;
        internal int YCountChars;
        internal int FillAttribute;
        internal int Flags;
        internal short ShowWindow;
        internal short Reserved2;
        internal IntPtr Reserved2Pointer;
        internal IntPtr StdInput;
        internal IntPtr StdOutput;
        internal IntPtr StdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ProcessInformation
    {
        internal IntPtr Process;
        internal IntPtr Thread;
        internal int ProcessId;
        internal int ThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobObjectBasicLimitInformation
    {
        internal long PerProcessUserTimeLimit;
        internal long PerJobUserTimeLimit;
        internal uint LimitFlags;
        internal UIntPtr MinimumWorkingSetSize;
        internal UIntPtr MaximumWorkingSetSize;
        internal uint ActiveProcessLimit;
        internal UIntPtr Affinity;
        internal uint PriorityClass;
        internal uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct IoCounters
    {
        internal ulong ReadOperationCount;
        internal ulong WriteOperationCount;
        internal ulong OtherOperationCount;
        internal ulong ReadTransferCount;
        internal ulong WriteTransferCount;
        internal ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct JobObjectExtendedLimitInformation
    {
        internal JobObjectBasicLimitInformation BasicLimitInformation;
        internal IoCounters IoInfo;
        internal UIntPtr ProcessMemoryLimit;
        internal UIntPtr JobMemoryLimit;
        internal UIntPtr PeakProcessMemoryUsed;
        internal UIntPtr PeakJobMemoryUsed;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "CreateProcessW", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool CreateProcess(
        [MarshalAs(UnmanagedType.LPWStr)] string applicationName,
        [MarshalAs(UnmanagedType.LPWStr)] string commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        [MarshalAs(UnmanagedType.LPWStr)] string? currentDirectory,
        ref StartupInfo startupInfo,
        out ProcessInformation processInformation);

    [LibraryImport("kernel32.dll", EntryPoint = "ResumeThread", SetLastError = true)]
    internal static partial uint ResumeThread(IntPtr thread);

    [LibraryImport("kernel32.dll", EntryPoint = "WaitForSingleObject", SetLastError = true)]
    internal static partial uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [LibraryImport("kernel32.dll", EntryPoint = "GetExitCodeProcess", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [LibraryImport("kernel32.dll", EntryPoint = "TerminateProcess", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool TerminateProcess(IntPtr process, uint exitCode);

    [LibraryImport("kernel32.dll", EntryPoint = "CloseHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool CloseHandle(IntPtr handle);

    [LibraryImport("kernel32.dll", EntryPoint = "CreateJobObjectW", SetLastError = true)]
    internal static partial IntPtr CreateJobObject(IntPtr jobAttributes, IntPtr name);

    [LibraryImport("kernel32.dll", EntryPoint = "SetInformationJobObject", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool SetInformationJobObject(
        IntPtr job,
        int informationClass,
        ref JobObjectExtendedLimitInformation information,
        uint informationLength);

    [LibraryImport("kernel32.dll", EntryPoint = "AssignProcessToJobObject", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool AssignProcessToJobObject(IntPtr job, IntPtr process);
}
