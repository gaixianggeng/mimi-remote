using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace MimiRemote.Core;

/// <summary>
/// Launches a pinned Windows maintenance broker suspended, binds it to a
/// kill-on-close Job Object, verifies its mapped kernel image identity before
/// resuming execution, and keeps handles/pins alive until every process in the
/// job exits.
/// </summary>
public static class WindowsMaintenanceProcessRunner
{
    private const uint CreateSuspended = 0x00000004;
    private const uint CreateNoWindow = 0x08000000;
    private const uint ExtendedStartupInfoPresent = 0x00080000;
    private const int StartfUseStdHandles = 0x00000100;
    private const uint HandleFlagInherit = 0x00000001;
    private const uint GenericRead = 0x80000000;
    private const uint FileReadAttributes = 0x00000080;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileAttributeDirectory = 0x00000010;
    private const uint FileAttributeDevice = 0x00000040;
    private const uint FileAttributeReparsePoint = 0x00000400;
    private const uint VolumeNameNt = 0x00000002;
    private const uint ProcessNameNative = 0x00000001;
    private const uint Infinite = 0xFFFFFFFF;
    private const uint WaitObject0 = 0x00000000;
    private const int ErrorInsufficientBuffer = 122;
    private const int ErrorCancelled = 1223;

    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const int JobObjectAssociateCompletionPortClass = 7;
    private const int JobObjectExtendedLimitClass = 9;
    private const uint JobObjectMsgActiveProcessZero = 4;
    private const nint ProcThreadAttributeHandleList = 0x00020002;

    public static string FormatCommandLine(string executablePath, IReadOnlyList<string> arguments)
    {
        ArgumentNullException.ThrowIfNull(executablePath);
        ArgumentNullException.ThrowIfNull(arguments);

        var builder = new StringBuilder();
        AppendQuotedArgument(builder, executablePath);
        foreach (var argument in arguments)
        {
            builder.Append(' ');
            AppendQuotedArgument(builder, argument);
        }
        return builder.ToString();
    }

    private static void AppendQuotedArgument(StringBuilder builder, string argument)
    {
        if (argument.Length == 0)
        {
            builder.Append("\"\"");
            return;
        }
        if (argument.AsSpan().IndexOfAny(' ', '\t', '"') < 0)
        {
            builder.Append(argument);
            return;
        }
        builder.Append('"');
        for (var index = 0; index < argument.Length; index++)
        {
            var backslashes = 0;
            while (index < argument.Length && argument[index] == '\\')
            {
                backslashes++;
                index++;
            }
            if (index == argument.Length)
            {
                builder.Append('\\', backslashes * 2);
                break;
            }
            if (argument[index] == '"')
            {
                builder.Append('\\', (backslashes * 2) + 1);
                builder.Append('"');
                continue;
            }
            builder.Append('\\', backslashes);
            builder.Append(argument[index]);
        }
        builder.Append('"');
    }

    [SupportedOSPlatform("windows")]
    public static PinnedBrokerImage ReadFileIdentity(SafeFileHandle handle, string fullPath)
    {
        ArgumentNullException.ThrowIfNull(handle);
        ArgumentNullException.ThrowIfNull(fullPath);

        if (!GetFileInformationByHandle(handle, out var info)
            || (info.FileAttributes & (FileAttributeReparsePoint | FileAttributeDevice | FileAttributeDirectory)) != 0)
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
        }
        var nativePath = QueryFinalNativePath(handle);
        return new PinnedBrokerImage(
            fullPath,
            nativePath,
            info.VolumeSerialNumber,
            info.FileIndexHigh,
            info.FileIndexLow);
    }

    [SupportedOSPlatform("windows")]
    public static Task<MaintenanceBrokerProcessResult> RunBoundProcessAsync(
        PinnedBrokerImage broker,
        string[] arguments,
        CancellationToken cancellationToken) =>
        RunBoundProcessAsync(broker, arguments, Environment.SystemDirectory, cancellationToken);

    [SupportedOSPlatform("windows")]
    public static Task<MaintenanceBrokerProcessResult> RunBoundProcessAsync(
        PinnedBrokerImage broker,
        string[] arguments,
        string workingDirectory,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(broker);
        ArgumentNullException.ThrowIfNull(arguments);
        ArgumentNullException.ThrowIfNull(workingDirectory);

        return Task.Run(() => RunBoundProcessCore(broker, arguments, workingDirectory, cancellationToken), cancellationToken);
    }

    [SupportedOSPlatform("windows")]
    private static MaintenanceBrokerProcessResult RunBoundProcessCore(
        PinnedBrokerImage broker,
        string[] arguments,
        string workingDirectory,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var job = (nint)0;
        var iocp = (nint)0;
        var stdoutRead = (nint)0;
        var stdoutWrite = (nint)0;
        var stderrRead = (nint)0;
        var stderrWrite = (nint)0;
        var nulStdin = (nint)0;
        var attrListPtr = (nint)0;
        var attrListInitialized = false;
        var handleListPtr = (nint)0;
        var commandLinePtr = (nint)0;
        var processHandle = (nint)0;
        var threadHandle = (nint)0;

        try
        {
            job = CreateJobObjectW(0, 0);
            if (job == 0)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }
            var limits = new JobObjectExtendedLimitInformation();
            limits.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            if (!SetInformationJobObjectExtended(job, JobObjectExtendedLimitClass, ref limits, (uint)Marshal.SizeOf<JobObjectExtendedLimitInformation>()))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }

            iocp = CreateIoCompletionPort(new nint(-1), 0, 0, 1);
            if (iocp == 0)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }
            const nint completionKey = 1;
            var assoc = new JobObjectAssociateCompletionPort
            {
                CompletionKey = completionKey,
                CompletionPort = iocp,
            };
            if (!SetInformationJobObjectPort(job, JobObjectAssociateCompletionPortClass, ref assoc, (uint)Marshal.SizeOf<JobObjectAssociateCompletionPort>()))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }

            var inheritSecurity = new SecurityAttributes
            {
                Length = Marshal.SizeOf<SecurityAttributes>(),
                InheritHandle = true,
            };
            if (!CreatePipe(out stdoutRead, out stdoutWrite, ref inheritSecurity, 0)
                || !SetHandleInformation(stdoutRead, HandleFlagInherit, 0)
                || !CreatePipe(out stderrRead, out stderrWrite, ref inheritSecurity, 0)
                || !SetHandleInformation(stderrRead, HandleFlagInherit, 0))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }

            nulStdin = CreateFileRawW(
                "NUL",
                GenericRead,
                FileShareRead | FileShareWrite,
                ref inheritSecurity,
                OpenExisting,
                0,
                0);
            if (nulStdin == 0 || nulStdin == new nint(-1))
            {
                nulStdin = 0;
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }

            nuint attrListSize = 0;
            _ = InitializeProcThreadAttributeList(0, 1, 0, ref attrListSize);
            if (attrListSize == 0 || attrListSize > 65_536)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }
            attrListPtr = Marshal.AllocHGlobal((int)attrListSize);
            if (!InitializeProcThreadAttributeList(attrListPtr, 1, 0, ref attrListSize))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }
            attrListInitialized = true;

            handleListPtr = Marshal.AllocHGlobal(3 * IntPtr.Size);
            Marshal.WriteIntPtr(handleListPtr, 0, nulStdin);
            Marshal.WriteIntPtr(handleListPtr, IntPtr.Size, stdoutWrite);
            Marshal.WriteIntPtr(handleListPtr, 2 * IntPtr.Size, stderrWrite);
            if (!UpdateProcThreadAttribute(
                attrListPtr,
                0,
                ProcThreadAttributeHandleList,
                handleListPtr,
                (nuint)(3 * IntPtr.Size),
                0,
                0))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }

            commandLinePtr = Marshal.StringToHGlobalUni(FormatCommandLine(broker.FullPath, arguments));
            var startupInfo = new StartupInfoEx
            {
                StartupInfo = new StartupInfo
                {
                    Cb = Marshal.SizeOf<StartupInfoEx>(),
                    Flags = StartfUseStdHandles,
                    StdInput = nulStdin,
                    StdOutput = stdoutWrite,
                    StdError = stderrWrite,
                },
                AttributeList = attrListPtr,
            };

            var created = CreateProcessW(
                broker.FullPath,
                commandLinePtr,
                0,
                0,
                inheritHandles: true,
                ExtendedStartupInfoPresent | CreateSuspended | CreateNoWindow,
                0,
                workingDirectory,
                ref startupInfo,
                out var processInfo);

            CloseHandleIfOpen(ref nulStdin);
            CloseHandleIfOpen(ref stdoutWrite);
            CloseHandleIfOpen(ref stderrWrite);

            if (!created)
            {
                var err = Marshal.GetLastWin32Error();
                throw new MaintenanceFailureException(err == ErrorCancelled
                    ? MaintenanceFailureKind.UacCancelled
                    : MaintenanceFailureKind.LaunchFailed);
            }

            processHandle = processInfo.Process;
            threadHandle = processInfo.Thread;

            if (!VerifyProcessMatchesIdentity(processHandle, broker))
            {
                _ = TerminateProcess(processHandle, 1);
                _ = WaitForSingleObject(processHandle, 5_000);
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }

            if (!AssignProcessToJobObject(job, processHandle))
            {
                _ = TerminateProcess(processHandle, 1);
                _ = WaitForSingleObject(processHandle, 5_000);
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }

            if (ResumeThread(threadHandle) == uint.MaxValue)
            {
                _ = TerminateJobObject(job, 1);
                WaitForJobZeroProcesses(iocp, completionKey);
                throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
            }

            // Ownership of read pipe handles transfers to the SafeFileHandles below.
            using var stdoutReadHandle = new SafeFileHandle(stdoutRead, ownsHandle: true);
            stdoutRead = 0;
            using var stderrReadHandle = new SafeFileHandle(stderrRead, ownsHandle: true);
            stderrRead = 0;

            var stdoutTask = Task.Run(() => ReadBoundedHandle(stdoutReadHandle, 262_144));
            var stderrTask = Task.Run(() => ReadBoundedHandle(stderrReadHandle, 65_536));

            uint exitCode = 0;
            try
            {
                using (cancellationToken.Register(() => _ = TerminateJobObject(job, 1)))
                {
                    var waitResult = WaitForSingleObject(processHandle, Infinite);
                    if (waitResult != WaitObject0 || !GetExitCodeProcess(processHandle, out exitCode))
                    {
                        _ = TerminateJobObject(job, 1);
                        WaitForJobZeroProcesses(iocp, completionKey);
                        cancellationToken.ThrowIfCancellationRequested();
                        throw new MaintenanceFailureException(MaintenanceFailureKind.LaunchFailed);
                    }

                    // Keep all directory and binary pins active until every descendant
                    // in the Job Object (including Inno's setup child) has exited.
                    WaitForJobZeroProcesses(iocp, completionKey);
                }
            }
            finally
            {
                if (!stdoutTask.IsCompleted || !stderrTask.IsCompleted)
                {
                    _ = TerminateJobObject(job, 1);
                    WaitForJobZeroProcesses(iocp, completionKey);
                }
                Task.WaitAll(stdoutTask, stderrTask);
            }

            cancellationToken.ThrowIfCancellationRequested();
            return new MaintenanceBrokerProcessResult(stdoutTask.Result, stderrTask.Result, unchecked((int)exitCode));
        }
        finally
        {
            CloseHandleIfOpen(ref threadHandle);
            CloseHandleIfOpen(ref processHandle);
            CloseHandleIfOpen(ref nulStdin);
            CloseHandleIfOpen(ref stdoutWrite);
            CloseHandleIfOpen(ref stderrWrite);
            CloseHandleIfOpen(ref stdoutRead);
            CloseHandleIfOpen(ref stderrRead);
            if (attrListInitialized && attrListPtr != 0)
            {
                DeleteProcThreadAttributeList(attrListPtr);
            }
            if (attrListPtr != 0)
            {
                Marshal.FreeHGlobal(attrListPtr);
            }
            if (handleListPtr != 0)
            {
                Marshal.FreeHGlobal(handleListPtr);
            }
            if (commandLinePtr != 0)
            {
                Marshal.FreeHGlobal(commandLinePtr);
            }
            CloseHandleIfOpen(ref iocp);
            CloseHandleIfOpen(ref job);
        }
    }

    [SupportedOSPlatform("windows")]
    private static bool VerifyProcessMatchesIdentity(nint processHandle, PinnedBrokerImage broker)
    {
        if (string.IsNullOrEmpty(broker.NativeImagePath))
        {
            return false;
        }
        var nativePath = QueryProcessImagePath(processHandle, ProcessNameNative);
        if (nativePath is null || !string.Equals(nativePath, broker.NativeImagePath, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        if (!VerifyPathMatchesIdentity(broker.FullPath, broker))
        {
            return false;
        }
        var win32Path = QueryProcessImagePath(processHandle, 0);
        if (!string.IsNullOrEmpty(win32Path) && !VerifyPathMatchesIdentity(win32Path, broker))
        {
            return false;
        }
        return true;
    }

    [SupportedOSPlatform("windows")]
    private static bool VerifyPathMatchesIdentity(string path, PinnedBrokerImage broker)
    {
        using var handle = CreateFileW(
            path,
            FileReadAttributes,
            FileShareRead,
            0,
            OpenExisting,
            FileFlagOpenReparsePoint,
            0);
        if (handle.IsInvalid)
        {
            return false;
        }
        if (!GetFileInformationByHandle(handle, out var info)
            || (info.FileAttributes & (FileAttributeReparsePoint | FileAttributeDevice | FileAttributeDirectory)) != 0)
        {
            return false;
        }
        return info.VolumeSerialNumber == broker.VolumeSerialNumber
            && info.FileIndexHigh == broker.FileIndexHigh
            && info.FileIndexLow == broker.FileIndexLow;
    }

    [SupportedOSPlatform("windows")]
    private static string QueryFinalNativePath(SafeFileHandle handle)
    {
        var buffer = new char[4096];
        while (true)
        {
            var count = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Length, VolumeNameNt);
            if (count == 0)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }
            if (count < buffer.Length)
            {
                return new string(buffer, 0, (int)count);
            }
            if (count > 32_768)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }
            buffer = new char[count + 1];
        }
    }

    [SupportedOSPlatform("windows")]
    private static string? QueryProcessImagePath(nint processHandle, uint flags)
    {
        var buffer = new char[4096];
        while (true)
        {
            var size = (uint)buffer.Length;
            if (QueryFullProcessImageNameW(processHandle, flags, buffer, ref size))
            {
                return new string(buffer, 0, (int)size);
            }
            if (Marshal.GetLastWin32Error() != ErrorInsufficientBuffer || buffer.Length >= 32_768)
            {
                return null;
            }
            buffer = new char[buffer.Length * 2];
        }
    }

    [SupportedOSPlatform("windows")]
    private static void WaitForJobZeroProcesses(nint iocp, nint expectedKey)
    {
        while (GetQueuedCompletionStatus(iocp, out var msg, out var key, out _, Infinite))
        {
            if (key == expectedKey && msg == JobObjectMsgActiveProcessZero)
            {
                return;
            }
        }
    }

    private static string ReadBoundedHandle(SafeFileHandle handle, int limit)
    {
        using var stream = new FileStream(handle, FileAccess.Read, bufferSize: 4096, isAsync: false);
        using var reader = new StreamReader(stream, new UTF8Encoding(false), detectEncodingFromByteOrderMarks: false, bufferSize: 4096, leaveOpen: true);
        var builder = new StringBuilder();
        var buffer = new char[4096];
        int count;
        while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
        {
            var keep = Math.Min(count, limit - builder.Length);
            if (keep > 0)
            {
                builder.Append(buffer, 0, keep);
            }
        }
        return builder.ToString();
    }

    [SupportedOSPlatform("windows")]
    private static void CloseHandleIfOpen(ref nint handle)
    {
        if (handle != 0)
        {
            _ = CloseHandle(handle);
            handle = 0;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public nint SecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int Cb;
        public nint Reserved;
        public nint Desktop;
        public nint Title;
        public int X;
        public int Y;
        public int XSize;
        public int YSize;
        public int XCountChars;
        public int YCountChars;
        public int FillAttribute;
        public int Flags;
        public short ShowWindow;
        public short Reserved2;
        public nint Reserved2Pointer;
        public nint StdInput;
        public nint StdOutput;
        public nint StdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public nint AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public nint Process;
        public nint Thread;
        public int ProcessId;
        public int ThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public uint CreationTimeLow;
        public uint CreationTimeHigh;
        public uint LastAccessTimeLow;
        public uint LastAccessTimeHigh;
        public uint LastWriteTimeLow;
        public uint LastWriteTimeHigh;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize;
        public nuint MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public nuint ProcessMemoryLimit;
        public nuint JobMemoryLimit;
        public nuint PeakProcessMemoryUsed;
        public nuint PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectAssociateCompletionPort
    {
        public nint CompletionKey;
        public nint CompletionPort;
    }

    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        nint securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        nint templateFile);

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateFileRawW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        ref SecurityAttributes securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        nint templateFile);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle fileHandle, out ByHandleFileInformation fileInformation);

    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle fileHandle, [Out] char[] filePath, uint filePathSize, uint flags);

    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageNameW(nint processHandle, uint flags, [Out] char[] exeName, ref uint size);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreatePipe(out nint readPipe, out nint writePipe, ref SecurityAttributes pipeAttributes, uint size);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetHandleInformation(nint handle, uint mask, uint flags);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(nint attributeList, uint attributeCount, uint flags, ref nuint size);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(
        nint attributeList,
        uint flags,
        nint attribute,
        nint value,
        nuint size,
        nint previousValue,
        nint returnSize);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern void DeleteProcThreadAttributeList(nint attributeList);

    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcessW(
        string applicationName,
        nint commandLine,
        nint processAttributes,
        nint threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags,
        nint environment,
        string currentDirectory,
        ref StartupInfoEx startupInfo,
        out ProcessInformation processInformation);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint ResumeThread(nint threadHandle);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern uint WaitForSingleObject(nint handle, uint milliseconds);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(nint processHandle, out uint exitCode);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(nint processHandle, uint exitCode);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern nint CreateJobObjectW(nint jobAttributes, nint name);

    [DllImport("kernel32.dll", EntryPoint = "SetInformationJobObject", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObjectExtended(
        nint job,
        int informationClass,
        ref JobObjectExtendedLimitInformation information,
        uint informationLength);

    [DllImport("kernel32.dll", EntryPoint = "SetInformationJobObject", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObjectPort(
        nint job,
        int informationClass,
        ref JobObjectAssociateCompletionPort information,
        uint informationLength);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(nint job, nint processHandle);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateJobObject(nint job, uint exitCode);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern nint CreateIoCompletionPort(nint fileHandle, nint existingCompletionPort, nint completionKey, uint numberOfConcurrentThreads);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetQueuedCompletionStatus(
        nint completionPort,
        out uint numberOfBytesTransferred,
        out nint completionKey,
        out nint overlapped,
        uint milliseconds);
}
