using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;
using MimiRemote.Core;

namespace MimiRemote.App;

/// <summary>
/// Windows native verification and pinning implementation for the trusted
/// maintenance contract (mimi.windows.maintenance/v1). Never consults PATH,
/// registry uninstall keys, uninstaller executables, Downloads, or diagnostics.
/// </summary>
internal sealed class WindowsMaintenanceNative : IWindowsMaintenancePlatform
{
    private const uint TokenQuery = 0x0008;
    private const int TokenElevationInfoClass = 20;

    private const uint GenericRead = 0x80000000;
    private const uint FileListDirectory = 0x00000001;
    private const uint FileReadAttributes = 0x00000080;
    private const uint FileShareRead = 0x00000001;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileFlagOpenReparsePoint = 0x00200000;

    private const uint FileAttributeDirectory = 0x00000010;
    private const uint FileAttributeDevice = 0x00000040;
    private const uint FileAttributeReparsePoint = 0x00000400;

    private const int ErrorFileNotFound = 2;
    private const int ErrorPathNotFound = 3;

    private const uint WtdUiNone = 2;
    private const uint WtdRevokeNone = 0;
    private const uint WtdChoiceFile = 1;
    private const uint WtdStateActionVerify = 1;
    private const uint WtdStateActionClose = 2;
    private const uint WtdCacheOnlyUrlRetrieval = 0x00001000;

    private static readonly Guid WinTrustActionGenericVerifyV2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");

    internal static string ResolveTrustedInstallDirectory() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Mimi Remote");

    internal static string? ResolveExpectedVersion(ClientBuild build) =>
        WindowsMaintenanceClient.ResolveExpectedVersion(build);

    internal static string? ResolvePreTrustedPublisherSha256(ClientBuild build, Assembly assembly) =>
        WindowsMaintenanceClient.ResolvePreTrustedPublisherSha256(build, assembly);

    public bool IsElevated()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out var tokenHandle))
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.ElevatedSession);
        }
        try
        {
            uint elevated = 0;
            uint returned = 0;
            if (!GetTokenInformation(tokenHandle, TokenElevationInfoClass, ref elevated, sizeof(uint), out returned)
                || returned < sizeof(uint))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.ElevatedSession);
            }
            return elevated != 0;
        }
        finally
        {
            _ = CloseHandle(tokenHandle);
        }
    }

    public async Task WithPinnedInstallAsync(
        string installDirectory,
        Func<IPinnedMaintenanceDirectory, Task> action,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var cleaned = installDirectory.Trim().TrimEnd('\\');
        if (string.IsNullOrEmpty(cleaned) || !Path.IsPathFullyQualified(cleaned))
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
        }
        if (cleaned.StartsWith(@"\\", StringComparison.Ordinal)
            && !cleaned.StartsWith(@"\\?\Volume{", StringComparison.OrdinalIgnoreCase))
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
        }

        var (volumeRoot, remainder) = SplitVolumeAndRemainder(cleaned);
        var current = ResolveVolumeGuidRoot(volumeRoot);
        var parts = remainder.Split('\\');
        using var pinned = new PinnedDirectoryScope();
        foreach (var part in parts)
        {
            if (string.IsNullOrEmpty(part) || part is "." or ".." || part.Contains(':', StringComparison.Ordinal) || part.Contains('/', StringComparison.Ordinal))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
            }
            current = current.TrimEnd('\\') + "\\" + part;
            var handle = CreateFileW(
                current,
                FileListDirectory | FileReadAttributes,
                FileShareRead,
                0,
                OpenExisting,
                FileFlagOpenReparsePoint | FileFlagBackupSemantics,
                0);
            if (handle.IsInvalid)
            {
                var err = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new MaintenanceFailureException(err is ErrorFileNotFound or ErrorPathNotFound
                    ? MaintenanceFailureKind.ReceiptMissing
                    : MaintenanceFailureKind.ReparsePointRejected);
            }
            pinned.AddHandle(handle);
            if (!GetFileInformationByHandle(handle, out var info)
                || (info.FileAttributes & (FileAttributeReparsePoint | FileAttributeDevice)) != 0
                || (info.FileAttributes & FileAttributeDirectory) == 0)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
            }
        }
        pinned.VolumeDirectory = current;
        await action(pinned).ConfigureAwait(false);
    }

    public byte[] VerifyCmsReceipt(byte[] rawReceipt, ReadOnlySpan<byte> expectedPublisher) =>
        WindowsMaintenanceCmsVerifier.VerifyCmsReceipt(rawReceipt, expectedPublisher);

    public Task<MaintenanceBrokerProcessResult> RunBrokerAsync(
        PinnedBrokerImage pinnedBroker,
        string[] arguments,
        CancellationToken cancellationToken) =>
        WindowsMaintenanceProcessRunner.RunBoundProcessAsync(
            pinnedBroker,
            arguments,
            killOnCancel: !WindowsMaintenanceClient.IsModifyCommand(arguments),
            cancellationToken);

    private static (string VolumeRoot, string Remainder) SplitVolumeAndRemainder(string cleaned)
    {
        if (cleaned.StartsWith(@"\\?\Volume{", StringComparison.OrdinalIgnoreCase))
        {
            var slash = cleaned.IndexOf('\\', 4);
            if (slash < 0 || slash + 1 >= cleaned.Length)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
            }
            return (cleaned[..slash], cleaned[(slash + 1)..]);
        }
        if (cleaned.Length < 4 || cleaned[1] != ':' || cleaned[2] != '\\')
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
        }
        return (cleaned[..2], cleaned[3..]);
    }

    private static string ResolveVolumeGuidRoot(string volume)
    {
        if (volume.StartsWith(@"\\?\Volume{", StringComparison.OrdinalIgnoreCase))
        {
            var inner = volume[@"\\?\".Length..];
            if (inner.Length != "Volume{00000000-0000-0000-0000-000000000000}".Length
                || !Guid.TryParse(inner[6..], out _))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
            }
            return volume;
        }
        if (volume.Length != 2 || volume[1] != ':')
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
        }
        var buffer = new char[64];
        if (!GetVolumeNameForVolumeMountPointW(volume + @"\", buffer, (uint)buffer.Length))
        {
            throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
        }
        var end = Array.IndexOf(buffer, '\0');
        var resolved = end >= 0 ? new string(buffer, 0, end) : new string(buffer);
        return string.IsNullOrEmpty(resolved)
            ? throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected)
            : resolved;
    }

    private static byte[]? VerifyAuthenticodeAndExtractSignerSha256(SafeFileHandle handle, string path)
    {
        var addedRef = false;
        handle.DangerousAddRef(ref addedRef);
        var filePtr = (nint)0;
        try
        {
            var fileInfo = new WinTrustFileInfo
            {
                Size = (uint)Marshal.SizeOf<WinTrustFileInfo>(),
                FilePath = path,
                FileHandle = handle.DangerousGetHandle(),
            };
            filePtr = Marshal.AllocHGlobal(Marshal.SizeOf<WinTrustFileInfo>());
            Marshal.StructureToPtr(fileInfo, filePtr, false);
            var data = new WinTrustData
            {
                Size = (uint)Marshal.SizeOf<WinTrustData>(),
                UiChoice = WtdUiNone,
                RevocationChecks = WtdRevokeNone,
                UnionChoice = WtdChoiceFile,
                File = filePtr,
                StateAction = WtdStateActionVerify,
                ProviderFlags = WtdCacheOnlyUrlRetrieval,
            };
            var action = WinTrustActionGenericVerifyV2;
            var verifyResult = WinVerifyTrust(new nint(-1), ref action, ref data);
            byte[]? signerSha256 = null;
            if (verifyResult == 0 && data.StateData != 0)
            {
                signerSha256 = ExtractSignerSha256FromStateData(data.StateData);
            }
            data.StateAction = WtdStateActionClose;
            var closeResult = WinVerifyTrust(new nint(-1), ref action, ref data);
            return verifyResult == 0 && closeResult == 0 ? signerSha256 : null;
        }
        finally
        {
            if (filePtr != 0)
            {
                Marshal.DestroyStructure<WinTrustFileInfo>(filePtr);
                Marshal.FreeHGlobal(filePtr);
            }
            if (addedRef)
            {
                handle.DangerousRelease();
            }
        }
    }

    private static byte[]? ExtractSignerSha256FromStateData(nint stateData)
    {
        var provData = WTHelperProvDataFromStateData(stateData);
        if (provData == 0)
        {
            return null;
        }
        var signer = WTHelperGetProvSignerFromChain(provData, 0, false, 0);
        if (signer == 0)
        {
            return null;
        }
        var certPtr = WTHelperGetProvCertFromChain(signer, 0);
        if (certPtr == 0)
        {
            return null;
        }
        var provCert = Marshal.PtrToStructure<CryptProviderCert>(certPtr);
        if (provCert.CertContext == 0)
        {
            return null;
        }
        var certCtx = Marshal.PtrToStructure<CertContextNative>(provCert.CertContext);
        if (certCtx.EncodedCert == 0 || certCtx.EncodedLength == 0 || certCtx.EncodedLength > 1_048_576)
        {
            return null;
        }
        var der = new byte[certCtx.EncodedLength];
        Marshal.Copy(certCtx.EncodedCert, der, 0, der.Length);
        return SHA256.HashData(der);
    }

    private sealed class PinnedDirectoryScope : IPinnedMaintenanceDirectory, IDisposable
    {
        private readonly List<SafeFileHandle> handles = [];

        public string VolumeDirectory { get; set; } = "";

        public void AddHandle(SafeFileHandle handle) => handles.Add(handle);

        public byte[] ReadReceipt(string fileName, int maxBytes)
        {
            var (handle, _) = OpenPinnedRegularFile(fileName, MaintenanceFailureKind.ReceiptMissing);
            var length = RandomAccess.GetLength(handle);
            if (length <= 0 || length > maxBytes)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
            }
            var result = new byte[(int)length];
            var total = 0;
            while (total < result.Length)
            {
                var read = RandomAccess.Read(handle, result.AsSpan(total), total);
                if (read == 0)
                {
                    break;
                }
                total += read;
            }
            return total == result.Length
                ? result
                : throw new MaintenanceFailureException(MaintenanceFailureKind.IdentityMismatch);
        }

        public PinnedBrokerImage VerifyPinnedImage(string fileName, ReadOnlySpan<byte> expectedDigest, ReadOnlySpan<byte> expectedPublisher)
        {
            var (handle, fullPath) = OpenPinnedRegularFile(fileName, MaintenanceFailureKind.MaintenanceImageMissing);
            using var hasher = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[65_536];
            long offset = 0;
            int read;
            while ((read = RandomAccess.Read(handle, buffer, offset)) > 0)
            {
                hasher.AppendData(buffer, 0, read);
                offset += read;
            }
            var actualDigest = hasher.GetHashAndReset();
            if (!CryptographicOperations.FixedTimeEquals(actualDigest, expectedDigest))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.DigestMismatch);
            }
            var signerSha256 = VerifyAuthenticodeAndExtractSignerSha256(handle, fullPath);
            if (signerSha256 is null || !CryptographicOperations.FixedTimeEquals(signerSha256, expectedPublisher))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.AuthenticodeFailed);
            }
            return WindowsMaintenanceProcessRunner.ReadFileIdentity(handle, fullPath);
        }

        private (SafeFileHandle Handle, string FullPath) OpenPinnedRegularFile(string fileName, MaintenanceFailureKind missingKind)
        {
            if (string.IsNullOrEmpty(fileName) || fileName is "." or ".."
                || fileName.Contains('\\', StringComparison.Ordinal)
                || fileName.Contains('/', StringComparison.Ordinal)
                || fileName.Contains(':', StringComparison.Ordinal))
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
            }
            var fullPath = VolumeDirectory.TrimEnd('\\') + "\\" + fileName;
            var handle = CreateFileW(
                fullPath,
                GenericRead,
                FileShareRead,
                0,
                OpenExisting,
                FileFlagOpenReparsePoint,
                0);
            if (handle.IsInvalid)
            {
                var err = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new MaintenanceFailureException(err is ErrorFileNotFound or ErrorPathNotFound
                    ? missingKind
                    : MaintenanceFailureKind.IdentityMismatch);
            }
            handles.Add(handle);
            if (!GetFileInformationByHandle(handle, out var info)
                || (info.FileAttributes & (FileAttributeReparsePoint | FileAttributeDevice | FileAttributeDirectory)) != 0)
            {
                throw new MaintenanceFailureException(MaintenanceFailureKind.ReparsePointRejected);
            }
            return (handle, fullPath);
        }

        public void Dispose()
        {
            for (var i = handles.Count - 1; i >= 0; i--)
            {
                handles[i].Dispose();
            }
            handles.Clear();
        }
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
    private struct CertContextNative
    {
        public uint EncodingType;
        public nint EncodedCert;
        public uint EncodedLength;
        public nint CertInfo;
        public nint CertStore;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct CryptProviderCert
    {
        public uint Size;
        public nint CertContext;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustFileInfo
    {
        public uint Size;
        [MarshalAs(UnmanagedType.LPWStr)] public string FilePath;
        public nint FileHandle;
        public nint KnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WinTrustData
    {
        public uint Size;
        public nint PolicyCallback;
        public nint SipClient;
        public uint UiChoice;
        public uint RevocationChecks;
        public uint UnionChoice;
        public nint File;
        public uint StateAction;
        public nint StateData;
        public nint UrlReference;
        public uint ProviderFlags;
        public uint UiContext;
        public nint SignatureSettings;
    }

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern nint GetCurrentProcess();

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);

    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenProcessToken(nint processHandle, uint desiredAccess, out nint tokenHandle);

    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetTokenInformation(nint tokenHandle, int tokenInformationClass, ref uint tokenInformation, uint tokenInformationLength, out uint returnLength);

    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        nint securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        nint templateFile);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle fileHandle, out ByHandleFileInformation fileInformation);

    [DllImport("kernel32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetVolumeNameForVolumeMountPointW(string volumeMountPoint, [Out] char[] volumeName, uint bufferLength);

    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int WinVerifyTrust(nint window, ref Guid action, ref WinTrustData data);

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern nint WTHelperProvDataFromStateData(nint stateData);

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern nint WTHelperGetProvSignerFromChain(nint provData, uint signerIndex, [MarshalAs(UnmanagedType.Bool)] bool counterSigner, uint counterSignerIndex);

    [DllImport("wintrust.dll", ExactSpelling = true)]
    private static extern nint WTHelperGetProvCertFromChain(nint signer, uint certIndex);
}
